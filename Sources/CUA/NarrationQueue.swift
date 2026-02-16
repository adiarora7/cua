import Foundation
import AVFoundation

// MARK: - TTSBackend Protocol

/// Backend-agnostic TTS interface. Both SystemTTS (AVSpeechSynthesizer) and Kokoro implement this.
protocol TTSBackend: Sendable {
    /// Speak text. Call completion when finished.
    func speak(_ text: String, completion: @escaping @Sendable () -> Void)
    /// Stop current speech immediately.
    func stop()
    /// Whether the backend is currently speaking.
    var isSpeaking: Bool { get }
}

// MARK: - SystemTTSBackend (AVSpeechSynthesizer wrapper)

/// Default TTS backend wrapping AVSpeechSynthesizer.
final class SystemTTSBackend: NSObject, @unchecked Sendable, TTSBackend, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let ttsVoice: AVSpeechSynthesisVoice?
    private var completionHandler: (@Sendable () -> Void)?

    init(voice: AVSpeechSynthesisVoice? = nil) {
        self.ttsVoice = voice
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, completion: @escaping @Sendable () -> Void) {
        completionHandler = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = ttsVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let handler = completionHandler
        completionHandler = nil
        handler?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Cancellation handled by NarrationQueue — don't call completion.
        completionHandler = nil
    }
}

// MARK: - NarrationQueue

/// Thread-safe FIFO queue that manages TTS independently from the action loop.
/// Speak and act simultaneously — enqueue() returns immediately, speech plays in background.
/// Uses pluggable TTSBackend — default is SystemTTSBackend (AVSpeechSynthesizer).
final class NarrationQueue: @unchecked Sendable {
    private var backend: TTSBackend
    private var queue: [String] = []
    private let lock = NSLock()
    private let logger: SessionLogger?

    /// Continuation for enqueueAndWait — resumed when the specific utterance finishes.
    private var waitContinuation: CheckedContinuation<Void, Never>?

    /// Whether the backend is currently speaking (set by callbacks).
    private var _isSpeaking = false

    /// When muted, enqueue() silently drops items. Used while mic is active to prevent echo.
    private var _muted = false

    /// Set during interruptAndEnqueue's 50ms debounce delay. Prevents isActive from returning
    /// false between interrupt and the delayed enqueue, which would cause the voice loop to
    /// start listen() (muting narration) before TTS plays.
    private var _pendingEnqueue = false

    init(voice: AVSpeechSynthesisVoice? = nil, logger: SessionLogger? = nil) {
        self.backend = SystemTTSBackend(voice: voice)
        self.logger = logger
    }

    init(backend: TTSBackend, logger: SessionLogger? = nil) {
        self.backend = backend
        self.logger = logger
    }

    /// Swap the TTS backend mid-session. Stops current speech, clears queue.
    func swapBackend(_ newBackend: TTSBackend) {
        lock.lock()
        queue.removeAll()
        _isSpeaking = false
        let cont = waitContinuation
        waitContinuation = nil
        lock.unlock()

        backend.stop()
        cont?.resume()
        backend = newBackend
        logger?.log("[narration] swapped TTS backend to \(type(of: newBackend))")
    }

    // MARK: - Public API

    /// Non-blocking. Speaks immediately if idle, otherwise queues.
    /// Silently drops items when muted (mic is active).
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        if _muted {
            lock.unlock()
            logger?.log("[narration] muted, dropped: \(trimmed)")
            return
        }
        if _isSpeaking {
            queue.append(trimmed)
            lock.unlock()
            logger?.log("[narration] queued: \(trimmed)")
        } else {
            _isSpeaking = true
            lock.unlock()
            speakNow(trimmed)
        }
    }

    /// Blocking. Enqueues and waits for this specific text to finish speaking.
    /// Use only for final summaries or "Ready" announcements.
    func enqueueAndWait(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _isSpeaking {
                queue.append(trimmed)
                self.waitContinuation = cont
                lock.unlock()
                logger?.log("[narration] queued+wait: \(trimmed)")
            } else {
                _isSpeaking = true
                self.waitContinuation = cont
                lock.unlock()
                speakNow(trimmed)
            }
        }
    }

    /// Stop current speech and clear queue.
    func cancelAll() {
        lock.lock()
        queue.removeAll()
        let cont = waitContinuation
        waitContinuation = nil
        _isSpeaking = false
        _pendingEnqueue = false
        lock.unlock()

        backend.stop()
        cont?.resume()
    }

    /// Cancel current speech. Returns true if was speaking.
    /// Used when user starts talking — interrupt TTS immediately.
    func interrupt() -> Bool {
        lock.lock()
        let wasSpeaking = _isSpeaking || !queue.isEmpty || _pendingEnqueue
        queue.removeAll()
        let cont = waitContinuation
        waitContinuation = nil
        _isSpeaking = false
        _pendingEnqueue = false
        lock.unlock()

        backend.stop()
        cont?.resume()
        return wasSpeaking
    }

    /// Whether the queue is actively speaking or has pending items.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSpeaking || !queue.isEmpty || _pendingEnqueue
    }

    /// Mute: stop current speech, clear queue, reject future enqueue() calls.
    /// Use when the mic opens to prevent TTS echo.
    func mute() {
        lock.lock()
        _muted = true
        queue.removeAll()
        let cont = waitContinuation
        waitContinuation = nil
        _isSpeaking = false
        _pendingEnqueue = false
        lock.unlock()

        backend.stop()
        cont?.resume()
        logger?.log("[narration] muted")
    }

    /// Unmute: allow enqueue() calls again. Call when mic closes.
    func unmute() {
        lock.lock()
        _muted = false
        lock.unlock()
        logger?.log("[narration] unmuted")
    }

    /// Interrupt current speech, clear queue, then enqueue new text after a brief debounce.
    /// Used to preempt filler audio when real narration arrives.
    func interruptAndEnqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        queue.removeAll()
        let wasSpeaking = _isSpeaking
        _isSpeaking = false
        _pendingEnqueue = true  // Keep isActive true during the 50ms debounce
        let cont = waitContinuation
        waitContinuation = nil
        lock.unlock()

        if wasSpeaking {
            backend.stop()
            logger?.log("[perf] filler_preempted")
        }
        cont?.resume()

        // 50ms debounce for audio graph cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.lock.lock()
            self._pendingEnqueue = false
            self.lock.unlock()
            self.enqueue(trimmed)
        }
        logger?.log("[narration] preempted, now: \(trimmed)")
    }

    /// Drop all queued items but let the current utterance finish naturally.
    /// Use this when actions have moved ahead and queued narration is stale.
    func skipStale() {
        lock.lock()
        let dropped = queue.count
        queue.removeAll()
        lock.unlock()
        if dropped > 0 {
            logger?.log("[narration] skipped \(dropped) stale items")
        }
    }

    // MARK: - Private

    private func speakNow(_ text: String) {
        logger?.log("[narration] speaking: \(text)")
        backend.speak(text) { [weak self] in
            self?.handleSpeechFinished()
        }
    }

    private func handleSpeechFinished() {
        lock.lock()
        if let next = queue.first {
            queue.removeFirst()
            lock.unlock()
            speakNow(next)
        } else {
            _isSpeaking = false
            let cont = waitContinuation
            waitContinuation = nil
            lock.unlock()
            cont?.resume()
        }
    }
}
