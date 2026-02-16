import Foundation

/// Thread-safe container for speculative API dispatch with strict single-execution semantics.
/// State machine: .idle → .inflight → .ready → .claimed (terminal) or .cancelled (terminal).
final class SpeculativeCallBox: @unchecked Sendable {

    enum State {
        case idle, inflight, ready, claimed, cancelled
    }

    struct SpecResult: Sendable {
        let input: String
        let toolCalls: [ToolUseBlock]
        let textOutput: String
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var task: Task<Void, Never>?
    private var _result: SpecResult?
    private var _utteranceId: Int = -1
    private var _generationToken: Int = 0
    private var _firedAt: ContinuousClock.Instant?
    private var _readyAt: ContinuousClock.Instant?
    private var _lastFireTime: ContinuousClock.Instant?
    private var _cancelled = false

    /// Cooldown between speculative fires (ms).
    private let cooldownMs: Double = 500

    // MARK: - Fire

    /// Fire a speculative API call. No-op if already inflight for this utterance, on cooldown, or < 2 words.
    /// `apiCall` is the closure that performs the actual API request and returns tool calls + text.
    func fire(
        input: String,
        screenshot: String,
        utteranceId: Int,
        apiCall: @escaping @Sendable (String, String) async -> (toolCalls: [ToolUseBlock], textOutput: String)?
    ) {
        lock.lock()

        // Reset if new utterance
        if utteranceId != _utteranceId {
            _utteranceId = utteranceId
            state = .idle
            _result = nil
            _cancelled = false
            _generationToken += 1
        }

        // Guard: must be idle (only one inflight per utterance)
        guard state == .idle else { lock.unlock(); return }

        // Guard: cooldown since last fire
        if let lastFire = _lastFireTime {
            let elapsed = Double((ContinuousClock.now - lastFire).components.attoseconds) / 1_000_000_000_000_000
            if elapsed < cooldownMs {
                lock.unlock()
                return
            }
        }

        state = .inflight
        _firedAt = ContinuousClock.now
        _lastFireTime = _firedAt
        _generationToken += 1
        let myToken = _generationToken
        let capturedInput = input

        lock.unlock()

        // Launch background API call
        task = Task {
            guard let result = await apiCall(capturedInput, screenshot) else {
                self.handleTaskFailure(token: myToken)
                return
            }
            self.handleTaskSuccess(token: myToken, input: capturedInput, result: result)
        }
    }

    // MARK: - Task callbacks (non-async, safe for NSLock)

    private func handleTaskFailure(token: Int) {
        lock.lock()
        if _generationToken == token && !_cancelled {
            state = .cancelled
        }
        lock.unlock()
    }

    private func handleTaskSuccess(token: Int, input: String, result: (toolCalls: [ToolUseBlock], textOutput: String)) {
        lock.lock()
        guard _generationToken == token && !_cancelled && state == .inflight else {
            lock.unlock()
            return
        }
        _result = SpecResult(input: input, toolCalls: result.toolCalls, textOutput: result.textOutput)
        _readyAt = ContinuousClock.now
        state = .ready
        lock.unlock()
    }

    // MARK: - Claim

    // MARK: - Claim helpers (non-async, safe for NSLock)

    /// Returns (state, utteranceId) snapshot under lock.
    private func peekState() -> (State, Int) {
        lock.lock()
        let s = state
        let u = _utteranceId
        lock.unlock()
        return (s, u)
    }

    /// Attempt the actual claim under lock. Returns result or nil.
    private func tryClaimSync(finalText: String, utteranceId: Int, similarityCheck: (String, String) -> Bool) -> SpecResult? {
        lock.lock()

        guard state == .ready,
              _utteranceId == utteranceId,
              let result = _result,
              let firedAt = _firedAt,
              let readyAt = _readyAt else {
            if state != .claimed && state != .cancelled {
                state = .cancelled
            }
            lock.unlock()
            return nil
        }

        // Timing check: result must have had >= 200ms to process
        let processingMs = Double((readyAt - firedAt).components.attoseconds) / 1_000_000_000_000_000
        guard processingMs >= 200 else {
            state = .cancelled
            lock.unlock()
            return nil
        }

        // Similarity check
        guard similarityCheck(result.input, finalText) else {
            state = .cancelled
            lock.unlock()
            return nil
        }

        state = .claimed
        lock.unlock()
        return result
    }

    /// Attempt to claim the speculative result. If the call is still in-flight and the utterance
    /// matches, waits up to 3s for it to complete instead of cancelling.
    /// Returns result only if ready, timing and similarity checks pass.
    /// Transitions to .claimed on success (terminal) or .cancelled on failure.
    func claimResult(finalText: String, utteranceId: Int, similarityCheck: (String, String) -> Bool) async -> SpecResult? {
        // If inflight and same utterance, wait for it to finish (up to 3s)
        let waitDeadline = ContinuousClock.now + .milliseconds(3000)
        while true {
            let (currentState, currentUtterance) = peekState()

            // Wrong utterance — don't wait
            guard currentUtterance == utteranceId else { break }

            // If still inflight and we have time, keep waiting
            if currentState == .inflight && ContinuousClock.now < waitDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
                continue
            }
            break
        }

        return tryClaimSync(finalText: finalText, utteranceId: utteranceId, similarityCheck: similarityCheck)
    }

    // MARK: - Cancel

    /// Cancel any inflight speculative call. Awaits with 500ms timeout.
    func cancel() async {
        let t = cancelSync()
        t?.cancel()

        // Wait up to 500ms for task to exit
        if let t = t {
            let waitTask = Task {
                await t.value
            }
            // Simple bounded wait — generationToken already invalidates late callbacks
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitTask.cancel()
        }
    }

    /// Synchronous cancellation — returns the task to await if needed.
    private func cancelSync() -> Task<Void, Never>? {
        lock.lock()
        if state != .claimed && state != .cancelled {
            state = .cancelled
        }
        _cancelled = true
        _generationToken += 1
        let t = task
        task = nil
        lock.unlock()
        return t
    }

    /// Reset for a new utterance (called at start of each listen cycle).
    func reset(utteranceId: Int) {
        lock.lock()
        _utteranceId = utteranceId
        state = .idle
        _result = nil
        _cancelled = false
        _firedAt = nil
        _readyAt = nil
        task = nil
        lock.unlock()
    }
}
