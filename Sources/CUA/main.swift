import Foundation
import AppKit

// Load .env file if present
func loadEnvFile() {
    let envPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env").path
    guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }
    for line in contents.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        let parts = trimmed.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        setenv(key, value, 0)
    }
}

// MARK: - Feature Flags & Instrumentation

/// Check if a feature flag environment variable is set to "1".
func featureEnabled(_ name: String) -> Bool {
    guard let val = getenv(name) else { return false }
    return String(cString: val) == "1"
}

/// Thread-safe ring buffer for tracking voice-to-first-action latency (P50/P95).
final class PerfTracker: @unchecked Sendable {
    private var samples: [Double] = []
    private let maxSamples = 50
    private let lock = NSLock()
    private var _noResultCount = 0

    func record(_ ms: Double) {
        lock.lock()
        samples.append(ms)
        if samples.count > maxSamples { samples.removeFirst() }
        lock.unlock()
    }

    func recordNoResult() {
        lock.lock()
        _noResultCount += 1
        lock.unlock()
    }

    func p50() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    func p95() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
        return sorted[idx]
    }

    func summary() -> String {
        lock.lock()
        let count = samples.count
        let noResult = _noResultCount
        let sorted = samples.sorted()
        lock.unlock()
        guard !sorted.isEmpty else { return "P50: n/a, P95: n/a (N=0, no-result=\(noResult))" }
        let p50 = sorted[sorted.count / 2]
        let p95idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
        let p95 = sorted[p95idx]
        return "P50: \(Int(p50))ms, P95: \(Int(p95))ms (N=\(count), no-result=\(noResult))"
    }
}

/// Per-utterance performance guard. Call exactly once per utterance — idempotent.
/// Thread-safe. Deinit logs untracked utterances as a safety net.
final class UtterancePerfGuard: @unchecked Sendable {
    let id: Int
    private let startTime: ContinuousClock.Instant
    private let logger: SessionLogger
    private let tracker: PerfTracker
    private var emitted = false
    private let lock = NSLock()

    init(id: Int, startTime: ContinuousClock.Instant, logger: SessionLogger, tracker: PerfTracker) {
        self.id = id
        self.startTime = startTime
        self.logger = logger
        self.tracker = tracker
    }

    func emitAction(source: String = "") {
        lock.lock()
        guard !emitted else { lock.unlock(); return }
        emitted = true
        lock.unlock()
        let ms = Double((ContinuousClock.now - startTime).components.attoseconds) / 1_000_000_000_000_000
        logger.log("[perf:U\(id)] voice_to_first_action \(Int(ms))ms\(source.isEmpty ? "" : " (\(source))")")
        tracker.record(ms)
    }

    func emitNoAction(reason: String) {
        lock.lock()
        guard !emitted else { lock.unlock(); return }
        emitted = true
        lock.unlock()
        logger.log("[perf:U\(id)] no_action (\(reason))")
        tracker.recordNoResult()
    }

    deinit {
        if !emitted {
            logger.log("[perf:U\(id)] no_action (untracked)")
            tracker.recordNoResult()
        }
    }
}

/// Monotonic utterance ID counter for perf tracking.
nonisolated(unsafe) var nextUtteranceCounter: Int = 0
func nextUtteranceId() -> Int {
    nextUtteranceCounter += 1
    return nextUtteranceCounter
}

// Max screenshots to keep in conversation history
let maxScreenshots = 3

/// Strip old screenshots, keeping only the most recent ones.
func trimHistory(_ history: inout [Message]) {
    var screenshotCount = 0
    for i in stride(from: history.count - 1, through: 0, by: -1) {
        let msg = history[i]
        let hasImage = msg.content.contains { if case .image = $0 { return true } else { return false } }
        if hasImage {
            screenshotCount += 1
            if screenshotCount > maxScreenshots {
                let trimmedContent = msg.content.map { block -> ContentBlock in
                    if case .image = block { return .text("[screenshot omitted]") }
                    return block
                }
                history[i] = Message(role: msg.role, content: trimmedContent)
            }
        }
        let hasToolResultImage = msg.content.contains {
            if case .toolResult(let tr) = $0 {
                return tr.content.contains { if case .image = $0 { return true } else { return false } }
            }
            return false
        }
        if hasToolResultImage {
            let trimmedContent = msg.content.map { block -> ContentBlock in
                if case .toolResult(let tr) = block {
                    let hasImg = tr.content.contains { if case .image = $0 { return true } else { return false } }
                    if hasImg {
                        screenshotCount += 1
                        if screenshotCount > maxScreenshots {
                            let trimmedInner = tr.content.map { inner -> ContentBlock in
                                if case .image = inner { return .text("[screenshot omitted]") }
                                return inner
                            }
                            return .toolResult(ToolResultBlock(toolUseId: tr.toolUseId, content: trimmedInner))
                        }
                    }
                }
                return block
            }
            history[i] = Message(role: msg.role, content: trimmedContent)
        }
    }
}

/// Thread-safe rolling context for conversation continuity across voice turns.
/// Stores recent "User: ... / Agent: ..." exchanges so Sonnet has memory.
final class SessionContext: @unchecked Sendable {
    private var lines: [String] = []
    private let maxLines = 10  // 5 exchanges × 2 lines
    private let lock = NSLock()

    func addUserTurn(_ input: String) {
        lock.lock()
        lines.append("User: \(input)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    func addAgentTurn(_ summary: String) {
        lock.lock()
        let short = String(summary.prefix(200))
        lines.append("Agent: \(short)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    func getContext() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Get context with memory prepended.
    func getContextWithMemory(_ memory: String?) -> String? {
        lock.lock()
        let ctx = lines.isEmpty ? nil : lines.joined(separator: "\n")
        lock.unlock()

        if let mem = memory, let ctx = ctx {
            return "\(mem)\n\n\(ctx)"
        }
        return memory ?? ctx
    }
}

/// Thread-safe box for passing pre-captured screenshot from STT callback to voice loop.
/// Used to overlap screenshot capture with the silence timeout in listen().
final class ScreenshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: String?
    var data: String? {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); _data = newValue; lock.unlock() }
    }
}

/// Thread-safe flag to track whether an async Task has completed.
/// Used to poll for task completion without blocking (unlike `await task.value`).
final class TaskCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _isDone = false
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return _isDone }
    func markDone() { lock.lock(); _isDone = true; lock.unlock() }
}

/// Thread-safe bridge for passing clarification answers between the voice loop and action task.
final class ClarificationBridge: @unchecked Sendable {
    private var continuation: CheckedContinuation<String?, Never>?
    private var _isPending = false
    private let lock = NSLock()

    /// Mark that a clarification is needed. Called before TTS asks the question.
    func markPending() {
        lock.lock()
        _isPending = true
        lock.unlock()
    }

    /// Whether a clarification answer is being awaited.
    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isPending
    }

    /// Wait for the voice loop to provide an answer.
    func waitForAnswer() async -> String? {
        await withCheckedContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()
        }
    }

    /// Provide an answer from the voice loop.
    func provideAnswer(_ answer: String) {
        lock.lock()
        let cont = continuation
        continuation = nil
        _isPending = false
        lock.unlock()
        cont?.resume(returning: answer)
    }

    /// Cancel any pending clarification.
    func cancel() {
        lock.lock()
        let cont = continuation
        continuation = nil
        _isPending = false
        lock.unlock()
        cont?.resume(returning: nil)
    }
}

/// Run Sonnet's action loop for a single work block.
/// Includes repeat detection — if Sonnet clicks the same spot 3+ times, injects a warning.
func runActionLoop(
    directive: String,
    screenshotData: String,
    client: AnthropicClient,
    executor: ActionExecutor,
    logger: SessionLogger,
    systemPrompt: String,
    maxIterations: Int,
    overlay: OverlayManager? = nil
) async -> (iterations: Int, hitLimit: Bool, lastScreenshot: String?) {
    var history: [Message] = []
    var latestScreenshot: String? = screenshotData

    // Repeat detection: track recent click coordinates
    var recentClicks: [(x: Int, y: Int)] = []
    let repeatThreshold = 2  // warn after 2 clicks near the same spot

    let imageSource = ImageSource(type: "base64", mediaType: "image/jpeg", data: screenshotData)
    history.append(Message(role: "user", content: [
        .image(imageSource),
        .text(directive)
    ]))

    var iterations = 0

    while iterations < maxIterations {
        if Task.isCancelled { return (iterations, false, latestScreenshot) }

        iterations += 1

        do {
            trimHistory(&history)

            overlay?.setState(.thinking)
            let response = try await client.sendMessage(
                messages: history,
                systemPrompt: systemPrompt
            )
            logger.log("[api #\(iterations)] stop: \(response.stopReason ?? "nil")")

            history.append(Message(role: "assistant", content: response.content))

            var toolUses: [ToolUseBlock] = []
            for block in response.content {
                switch block {
                case .text(let text):
                    if !text.isEmpty { logger.log("SONNET: \(text)") }
                case .toolUse(let toolUse):
                    toolUses.append(toolUse)
                default:
                    break
                }
            }

            let hasToolUse = !toolUses.isEmpty

            if hasToolUse {
                overlay?.setState(.acting)
                let batchStart = ContinuousClock.now
                for (i, toolUse) in toolUses.enumerated() {
                    if Task.isCancelled { return (iterations, false, latestScreenshot) }
                    if let action = ComputerAction(from: toolUse.input) {
                        logger.log("[action \(i+1)/\(toolUses.count)] \(action)")
                        await executor.execute(action)
                        try await Task.sleep(nanoseconds: 200_000_000)

                        // Track clicks for repeat detection
                        // Only reset on typing (meaningful state change), NOT on Escape/Tab/scroll
                        switch action {
                        case .leftClick(let x, let y), .doubleClick(let x, let y), .rightClick(let x, let y):
                            recentClicks.append((x: x, y: y))
                        case .type:
                            recentClicks.removeAll()
                        default:
                            break // Escape, Tab, scroll, mouseMove — don't reset
                        }
                    }
                }

                try await Task.sleep(nanoseconds: 300_000_000)
                let batchDuration = ContinuousClock.now - batchStart
                logger.log("[batch \(toolUses.count) actions] \(batchDuration)")

                // Check for repeated clicks — stuck on same target
                let repeatWarning = checkForRepeatedClicks(recentClicks, threshold: repeatThreshold)
                if repeatWarning != nil {
                    recentClicks.removeAll() // Reset after warning so it doesn't fire on every subsequent action
                }

                // Screenshot after batch
                if let (newScreenshot, _, _, _, _) = screenshotBase64() {
                    let newImageSource = ImageSource(type: "base64", mediaType: "image/jpeg", data: newScreenshot)
                    latestScreenshot = newScreenshot

                    var toolResultBlocks: [ContentBlock] = []
                    for (i, toolUse) in toolUses.enumerated() {
                        let actionDesc = ComputerAction(from: toolUse.input).map { actionDescription($0) } ?? toolUse.input.action
                        if i == toolUses.count - 1 {
                            var resultContent: [ContentBlock] = [
                                .text("Action executed: \(actionDesc)"),
                                .image(newImageSource)
                            ]
                            if let warning = repeatWarning {
                                resultContent.append(.text(warning))
                                logger.log("[repeat warning] \(warning)")
                            }
                            toolResultBlocks.append(.toolResult(ToolResultBlock(
                                toolUseId: toolUse.id,
                                content: resultContent
                            )))
                        } else {
                            toolResultBlocks.append(.toolResult(ToolResultBlock(
                                toolUseId: toolUse.id,
                                content: [.text("Action executed: \(actionDesc)")]
                            )))
                        }
                    }
                    history.append(Message(role: "user", content: toolResultBlocks))
                } else {
                    return (iterations, false, latestScreenshot)
                }
            }

            if response.stopReason == "tool_use" && hasToolUse {
                continue
            } else {
                return (iterations, false, latestScreenshot)
            }

        } catch {
            logger.log("[error] \(error)")
            return (iterations, false, latestScreenshot)
        }
    }

    return (iterations, true, latestScreenshot)
}

/// Check if recent clicks are all near the same coordinates.
func checkForRepeatedClicks(_ clicks: [(x: Int, y: Int)], threshold: Int) -> String? {
    guard clicks.count >= threshold else { return nil }
    let recent = clicks.suffix(threshold)
    let first = recent.first!
    let allNearSame = recent.allSatisfy { abs($0.x - first.x) < 30 && abs($0.y - first.y) < 30 }
    if allNearSame {
        return "WARNING: You have clicked the same spot \(threshold)+ times with no effect. STOP clicking this element. Switch to a KEYBOARD-ONLY approach: use Tab to move between fields, use app keyboard shortcuts (Gmail: 'c' to compose, Tab between To/Subject/Body), or press Escape first to dismiss any minimized/collapsed windows then retry with keyboard shortcuts."
    }
    return nil
}

/// Describe a computer action in human-readable form for tool result grounding.
/// Uses API coordinates (pre-scaling) since that's what the model understands.
func actionDescription(_ action: ComputerAction) -> String {
    switch action {
    case .leftClick(let x, let y): return "left_click at (\(x), \(y))"
    case .rightClick(let x, let y): return "right_click at (\(x), \(y))"
    case .doubleClick(let x, let y): return "double_click at (\(x), \(y))"
    case .middleClick(let x, let y): return "middle_click at (\(x), \(y))"
    case .type(let text): return "typed \"\(text.prefix(50))\""
    case .key(let keys): return "pressed \(keys)"
    case .scroll(_, _, let dir, let amt): return "scrolled \(dir) \(amt)x"
    case .mouseMove(let x, let y): return "mouse_move to (\(x), \(y))"
    case .leftClickDrag(let sx, let sy, let ex, let ey): return "dragged from (\(sx),\(sy)) to (\(ex),\(ey))"
    case .screenshot: return "screenshot"
    case .cursorPosition: return "cursor_position"
    }
}

/// Find the end of the first complete sentence in a buffer.
/// Splits on `.`, `!`, `?` followed by a space or end-of-string.
/// Returns the index just past the sentence-ending punctuation, or nil if no boundary found.
func findSentenceBoundary(_ text: String) -> String.Index? {
    let sentenceEnders: [Character] = [".", "!", "?"]
    var i = text.startIndex
    while i < text.endIndex {
        let char = text[i]
        if sentenceEnders.contains(char) {
            let next = text.index(after: i)
            if next == text.endIndex || text[next] == " " || text[next] == "\n" {
                return next
            }
        }
        i = text.index(after: i)
    }
    return nil
}

/// Strip GUIDE:/DONE:/NARRATE:/CLARIFY: prefixes from text for narration.
func stripNarratePrefix(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["NARRATE:", "GUIDE:", "DONE:", "CLARIFY:"] {
        if let range = trimmed.range(of: prefix) {
            // Find the prefix, strip it and everything before it
            let after = trimmed[range.upperBound...]
            // Also strip coordinate pattern like "(450, 52) " after GUIDE:
            let cleaned = String(after).trimmingCharacters(in: .whitespaces)
            if prefix == "GUIDE:" {
                // Remove leading (x, y) pattern
                let coordPattern = #"^\(\d+,\s*\d+\)\s*"#
                if let regex = try? NSRegularExpression(pattern: coordPattern),
                   let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
                    let afterCoord = String(cleaned[Range(match.range, in: cleaned)!.upperBound...])
                    return afterCoord.trimmingCharacters(in: .whitespaces)
                }
            }
            return cleaned
        }
    }
    return trimmed
}

/// Generate a short spoken description of an action for narration.
func describeAction(_ action: ComputerAction) -> String? {
    switch action {
    case .leftClick: return "Clicking there"
    case .doubleClick: return "Double-clicking"
    case .rightClick: return "Right-clicking"
    case .type(let text):
        let preview = text.count > 20 ? String(text.prefix(20)) + "..." : text
        return "Typing \(preview)"
    case .key(let keys):
        let lower = keys.lowercased()
        if lower == "return" { return "Pressing enter" }
        if lower.contains("cmd+l") { return "Focusing the address bar" }
        if lower.contains("cmd+space") { return "Opening Spotlight" }
        if lower.contains("cmd+t") { return "Opening new tab" }
        if lower.contains("cmd+w") { return "Closing tab" }
        if lower.contains("cmd+f") { return "Finding on page" }
        if lower == "tab" { return "Next field" }
        if lower == "escape" { return "Pressing escape" }
        return nil  // Don't narrate every key press
    case .scroll(_, _, let dir, _): return "Scrolling \(dir)"
    case .mouseMove: return nil
    case .middleClick: return nil
    case .leftClickDrag: return "Dragging"
    case .screenshot: return nil
    case .cursorPosition: return nil
    }
}

/// Execute a pipeline of work blocks. Returns a summary string.
/// If `clarificationAnswer` is provided, it's included in replan context when blocks fail.
func executePipeline(
    userInput: String,
    blocks: [Orchestrator.WorkBlock],
    orchestrator: Orchestrator,
    client: AnthropicClient,
    executor: ActionExecutor,
    logger: SessionLogger,
    sonnetPrompt: String,
    maxIterationsPerBlock: Int,
    maxReplans: Int,
    overlay: OverlayManager? = nil,
    clarificationAnswer: String? = nil
) async -> String {
    var currentBlocks = blocks
    var blockIndex = 0
    var totalIterations = 0
    var replanCount = 0
    var accomplishments: [String] = []

    while blockIndex < currentBlocks.count {
        if Task.isCancelled { return "Cancelled." }

        let block = currentBlocks[blockIndex]
        let blockLabel = "[Block \(blockIndex + 1)/\(currentBlocks.count)]"
        print("\(blockLabel) \(block.directive)")
        logger.log("[block \(blockIndex + 1)/\(currentBlocks.count)] \(block.directive)")
        logger.log("[block \(blockIndex + 1) expected] \(block.expectedOutcome)")

        // Take fresh screenshot for this block
        guard let (screenshotData, _, _, _, _) = screenshotBase64() else {
            return "Lost screen access."
        }

        // Execute block
        overlay?.setState(.acting, detail: "Block \(blockIndex + 1)/\(currentBlocks.count)")
        let (iterations, hitLimit, lastScreenshot) = await runActionLoop(
            directive: block.directive,
            screenshotData: screenshotData,
            client: client,
            executor: executor,
            logger: logger,
            systemPrompt: sonnetPrompt,
            maxIterations: maxIterationsPerBlock,
            overlay: overlay
        )
        totalIterations += iterations

        if Task.isCancelled { return "Cancelled." }

        let currentSS = lastScreenshot ?? screenshotData
        logger.log("[block \(blockIndex + 1) done] \(iterations) iter | hit_limit=\(hitLimit)")

        // Is this the last block? Full eval.
        let isLastBlock = blockIndex == currentBlocks.count - 1

        // Quick evaluation
        do {
            overlay?.setState(.thinking, detail: "Evaluating")
            let blockEval = try await orchestrator.evaluateBlock(
                expectedOutcome: block.expectedOutcome,
                screenshotBase64: currentSS,
                iterations: iterations,
                hitLimit: hitLimit,
                blockNumber: blockIndex + 1,
                totalBlocks: currentBlocks.count
            )

            switch blockEval {
            case .ok(let summary):
                accomplishments.append(summary)
                print("\(blockLabel) ✓ \(summary)")
                logger.log("[block \(blockIndex + 1) eval] OK: \(summary)")

                if isLastBlock {
                    return summary
                }
                // Fire next block immediately
                blockIndex += 1

            case .taskComplete(let summary):
                // Shouldn't happen anymore, but treat as ok for safety
                print("\(blockLabel) ✓ \(summary)")
                logger.log("[block \(blockIndex + 1) eval] COMPLETE: \(summary)")
                if isLastBlock {
                    return summary
                }
                accomplishments.append(summary)
                blockIndex += 1

            case .failed(let summary):
                print("\(blockLabel) ✗ \(summary)")
                logger.log("[block \(blockIndex + 1) eval] FAILED: \(summary)")

                replanCount += 1
                if replanCount > maxReplans {
                    let partial = accomplishments.isEmpty ? summary : accomplishments.joined(separator: ". ") + ". But then: " + summary
                    return partial
                }

                // Re-plan remaining work
                print("[Replanning \(replanCount)/\(maxReplans)]...")
                logger.log("[replan \(replanCount)/\(maxReplans)]")
                overlay?.setState(.thinking, detail: "Replanning")
                do {
                    let accomplished = accomplishments.isEmpty ? "Nothing yet" : accomplishments.joined(separator: ". ")
                    guard let (freshSS, _, _, _, _) = screenshotBase64() else {
                        return summary
                    }
                    // If clarification answer is available, use it in the replan for better context
                    let replanRequest = clarificationAnswer != nil
                        ? "\(userInput) (User clarified: \(clarificationAnswer!))"
                        : userInput
                    let newBlocks = try await orchestrator.replan(
                        userRequest: replanRequest,
                        accomplishedSoFar: accomplished,
                        screenshotBase64: freshSS
                    )
                    currentBlocks = newBlocks
                    blockIndex = 0
                    logger.log("[replan] \(newBlocks.count) new blocks")
                    for (i, b) in newBlocks.enumerated() {
                        logger.log("[replan block \(i+1)] \(b.directive)")
                    }
                } catch {
                    logger.log("[replan error] \(error)")
                    return summary
                }
            }
        } catch {
            logger.log("[block eval error] \(error)")
            // Eval failed — if last block, assume done; otherwise continue optimistically
            if isLastBlock {
                return "Task completed."
            }
            accomplishments.append("(block \(blockIndex + 1) completed, eval skipped)")
            blockIndex += 1
        }
    }

    let summary = accomplishments.isEmpty ? "Completed." : accomplishments.last ?? "Completed."
    return summary
}

// MARK: - Main

func run() async {
    // API key resolution: environment/.env first, then bundled demo key
    let bundledKey = "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"
    let envKeyRaw = getenv("ANTHROPIC_API_KEY")
    let envKey = envKeyRaw.flatMap { String(validatingCString: $0) } ?? ""
    let apiKey = envKey.isEmpty ? bundledKey : envKey
    guard !apiKey.isEmpty else {
        print("Error: ANTHROPIC_API_KEY not set.")
        print("Add it to .env file or: export ANTHROPIC_API_KEY=your_api_key")
        exit(1)
    }
    if envKey.isEmpty {
        print("Using bundled demo API key (limited usage).")
        print("Set ANTHROPIC_API_KEY in your environment to use your own key.")
    }

    print("Capturing screen...")
    guard let (_, width, height, logicalWidth, logicalHeight) = screenshotBase64() else {
        print("Error: Failed to capture screen.")
        print("Please grant screen recording permission in System Settings > Privacy & Security > Screen Recording")
        exit(1)
    }

    let logger = SessionLogger()
    // Use API dimensions (what the model sees) for coordinate space
    let client = AnthropicClient(apiKey: apiKey, displayWidth: width, displayHeight: height)
    client.logger = logger
    let executor = ActionExecutor()
    // Set scale factors: convert API coordinates → logical screen coordinates
    executor.scaleX = Double(logicalWidth) / Double(width)
    executor.scaleY = Double(logicalHeight) / Double(height)
    let orchestrator = Orchestrator(client: client, logger: logger)

    let voiceMode = CommandLine.arguments.contains("--voice")
    let overlay = OverlayManager()
    screenshotOverlay = overlay

    logger.log("Session started — screen \(width)x\(height) | mode=\(voiceMode ? "voice" : "text")")

    let sonnetPrompt = """
    You are a fast computer use assistant controlling a macOS computer. Screen: \(width)x\(height) pixels.

    SPEED IS CRITICAL:
    - Return MULTIPLE tool calls per response. Batch predictable sequences into one response. Example: to open an app, return key("cmd+space"), type("AppName"), key("Return") as THREE tool calls in ONE response.
    - You ALWAYS receive a fresh screenshot after your actions execute. NEVER use the screenshot action — it wastes time. Just perform real actions and observe the result.
    - Every response MUST include at least one action that changes the screen state. Don't just observe or wait — act.
    - Keep narration under 10 words. Be terse.

    macOS:
    - Open apps: Click the icon in the Dock if visible. Only use Spotlight (cmd+space) if the app isn't in the Dock.
    - Browser address bar: cmd+L to focus, then type URL, then Return
    - Find on page: cmd+F, then type search term
    - Close popups/menus: Escape
    - Navigate form fields: Tab key
    - Permissions dialog: Tell user to grant manually, then stop

    Actions:
    - Aim for CENTER of target elements
    - After 2 misses on the same target, try a COMPLETELY DIFFERENT approach (keyboard shortcut, Tab navigation, etc.)
    - Prefer keyboard shortcuts over clicking small UI elements
    - If a compose/dialog window appears minimized or collapsed to a bar at the bottom, DO NOT click the minimized bar repeatedly. Instead: press Escape to dismiss it, then use the keyboard shortcut to open a fresh one (e.g. in Gmail press 'c' to compose)
    - Gmail shortcuts: 'c' = new compose, 'r' = reply, 'a' = reply all, 'f' = forward, '/' = search, 'e' = archive
    - If clicking a UI element causes a window to minimize or collapse, STOP clicking it and switch to keyboard shortcuts
    - For left_click_drag: start_coordinate is WHERE to grab, coordinate is WHERE to release. The macOS dock occupies the bottom ~50px of the screen — window edges are ABOVE the dock. Target the visible window border, NOT the screen edge. Start drag ~5px INSIDE the window border to reliably grab the resize handle.

    STT quirks:
    - Speech-to-text may insert spaces in email addresses. ALWAYS remove spaces from email addresses before typing them. E.g., if the user says "arora710@gmail.com" it may arrive as "Arora 710@gmail.com" — type "arora710@gmail.com" (no space, lowercase).
    """

    // Sonnet-direct prompt: Sonnet handles entire task lifecycle
    // Supports three interaction modes: GUIDE, NARRATE+ACT, and ACT
    let sonnetDirectPrompt = """
    You are a helpful computer assistant on macOS. Screen: \(width)x\(height) pixels.

    You receive a user request and a screenshot. You have THREE ways to help:

    == MODE 1: GUIDE (preferred when user can do it themselves) ==
    Talk the user through what to do. Respond with ONLY text starting with:
      GUIDE: (x, y) Your spoken instruction here
    The system will highlight the spot on screen and speak your instruction.
    Examples:
      "GUIDE: (450, 52) Click on the address bar at the top of Chrome"
      "GUIDE: (0, 0) Press Command-Space to open Spotlight search"
    Use (0, 0) when the instruction is about a keyboard action, not a specific screen element.
    Keep instructions short and conversational (one sentence). No tool calls with GUIDE.
    After you GUIDE, you'll get a fresh screenshot showing what the user did.

    == MODE 2: NARRATE+ACT (you act AND narrate simultaneously) ==
    Take direct control AND narrate. Start your response with:
      NARRATE: Brief description (MAX 8 words)
    Then include your tool calls. Narration plays via TTS while actions execute.
    Examples:
      "NARRATE: Opening Chrome"
      "NARRATE: Searching for eggs"
      "NARRATE: Adding that to the cart"
    ONLY use NARRATE for the FIRST action in a new task or when the action changes direction.

    == MODE 3: ACT (silent — tool calls only, no text. DEFAULT for follow-ups) ==
    Just tool calls, no text. Use this for ALL follow-up actions in a sequence.
    After your first NARRATE, switch to ACT for subsequent steps. The user already knows what you're doing.

    == COMPLETION ==
    When the task is done, respond with ONLY: "DONE: (max 10 words)"
    Example: "DONE: Added organic eggs to your cart"

    == CLARIFICATION ==
    If the request is ambiguous: "CLARIFY: your question"

    == CHOOSING MODES ==
    - GUIDE for: navigation decisions, choosing between options, personal preferences, sensitive inputs, learning moments
    - NARRATE+ACT for: the FIRST action in a task only. One narration per task is enough.
    - ACT (silent) for: ALL follow-up actions. Don't narrate every click — it's annoying.
    - When in doubt between GUIDE and NARRATE+ACT, choose GUIDE. The user feels more in control.

    GUIDE tips:
    - Keep instructions under 15 words. They are spoken aloud via TTS — brevity is critical.
    - Reference what the user can SEE: "the blue button on the right", "the search bar at the top"
    - Be specific about location — don't say "click the button", say "click the blue Search button in the top right"
    - For keyboard actions, say "Press Command-L" not "I'll focus the address bar"
    - One step at a time. Never dump multiple instructions.
    - NEVER use bullet points, numbered lists, or multi-line responses. One short sentence only.
    - Your text response must start with GUIDE:, NARRATE:, DONE:, or CLARIFY: — nothing else before the prefix.

    NARRATE+ACT tips:
    - MAX 8 words. Everything is spoken aloud — brevity is critical.
    - Describe WHAT not HOW: "Opening Chrome" not "Pressing Cmd+Space and typing Chrome"
    - NEVER say "Perfect!", "Great!", "I can see..." — just act.
    - NEVER describe what you observe on screen — just do the next action.
    - Return MULTIPLE tool calls per response for speed

    ACT tips (when acting without narration):
    - Return MULTIPLE tool calls per response for speed
    - NEVER use the screenshot tool — you always get a fresh one after actions
    - Prefer URL parameters: google.com/search?q=query, amazon.com/s?k=terms
    - Open apps: click Dock icon if visible, otherwise Spotlight (cmd+space)
    - Browser address bar: cmd+L → type URL → Return
    - After 2 misses on same target, switch to keyboard approach
    - Gmail shortcuts: 'c' = compose, '/' = search, Tab between fields
    - For left_click_drag: start_coordinate is WHERE to grab, coordinate is WHERE to release. The macOS dock occupies the bottom ~50px — window edges are ABOVE the dock. Start drag ~5px INSIDE the visible window border to grab the resize handle, never at the screen edge.

    STT quirks:
    - Speech-to-text may insert spaces in email addresses. ALWAYS remove spaces from email addresses before typing them. E.g., "Arora 710@gmail.com" → type "arora710@gmail.com".
    """

    let maxIterationsPerBlock = 10
    let maxReplans = 2
    let maxDirectIterations = 15

    if voiceMode {
        await runVoiceMode(
            orchestrator: orchestrator,
            client: client,
            executor: executor,
            logger: logger,
            sonnetPrompt: sonnetPrompt,
            sonnetDirectPrompt: sonnetDirectPrompt,
            maxIterationsPerBlock: maxIterationsPerBlock,
            maxReplans: maxReplans,
            maxDirectIterations: maxDirectIterations,
            overlay: overlay
        )
    } else {
        await runTextMode(
            orchestrator: orchestrator,
            client: client,
            executor: executor,
            logger: logger,
            sonnetPrompt: sonnetPrompt,
            sonnetDirectPrompt: sonnetDirectPrompt,
            maxIterationsPerBlock: maxIterationsPerBlock,
            maxReplans: maxReplans,
            maxDirectIterations: maxDirectIterations,
            overlay: overlay
        )
    }

    print("Goodbye!")
    exit(0)
}

// MARK: - Sonnet-Direct: single Sonnet loop for entire task

/// Result of a Sonnet-direct run.
enum SonnetDirectResult {
    case done(String)           // DONE: summary
    case clarify(String)        // CLARIFY: question
    case escalate               // hit iteration limit, needs Opus
}

/// Parse a GUIDE response: "GUIDE: (x, y) instruction text"
/// Returns (x, y, instruction) or nil if format doesn't match.
func parseGuideResponse(_ text: String) -> (x: Int, y: Int, instruction: String)? {
    // Match: GUIDE: (digits, digits) rest of text
    let pattern = #"^GUIDE:\s*\((\d+),\s*(\d+)\)\s*(.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges >= 4,
          let xRange = Range(match.range(at: 1), in: text),
          let yRange = Range(match.range(at: 2), in: text),
          let instrRange = Range(match.range(at: 3), in: text),
          let x = Int(text[xRange]),
          let y = Int(text[yRange])
    else { return nil }
    return (x: x, y: y, instruction: String(text[instrRange]))
}

/// Run the assistant loop to handle the entire task.
/// Supports GUIDE (talk user through it) and ACT (tool calls) modes fluidly.
/// Uses Haiku for fast guidance, can escalate to Sonnet for complex actions.
func runSonnetDirect(
    userRequest: String,
    screenshotData: String,
    client: AnthropicClient,
    executor: ActionExecutor,
    logger: SessionLogger,
    systemPrompt: String,
    maxIterations: Int,
    model: ModelChoice = .haiku,
    overlay: OverlayManager? = nil,
    voice: VoiceManager? = nil,
    narrationQueue: NarrationQueue? = nil,
    sessionContext: String? = nil
) async -> SonnetDirectResult {
    var history: [Message] = []
    var didMaximize = false

    // Repeat detection
    var recentClicks: [(x: Int, y: Int)] = []
    let repeatThreshold = 2

    // Build the initial message with session context for continuity
    let fullRequest: String
    if let ctx = sessionContext, !ctx.isEmpty {
        fullRequest = "CONVERSATION SO FAR:\n\(ctx)\n\nNEW REQUEST: \(userRequest)"
    } else {
        fullRequest = userRequest
    }

    let imageSource = ImageSource(type: "base64", mediaType: "image/jpeg", data: screenshotData)
    history.append(Message(role: "user", content: [
        .image(imageSource),
        .text(fullRequest)
    ]))

    var iterations = 0

    while iterations < maxIterations {
        if Task.isCancelled { return .done("Cancelled.") }

        iterations += 1

        do {
            trimHistory(&history)

            // Drop stale narration from previous iteration before starting new one
            narrationQueue?.skipStale()

            overlay?.setState(.thinking)

            // Stream the response for early GUIDE detection + streaming narration
            var streamedText = ""
            var highlightShown = false
            var sentenceBuffer = ""
            var firstSentenceStreamed = false
            let capturedOverlay = overlay
            let capturedNarrationQueue = narrationQueue
            let response = try await client.streamMessage(
                messages: history,
                systemPrompt: systemPrompt,
                model: model,
                onTextDelta: { delta in
                    streamedText += delta
                    sentenceBuffer += delta

                    // Early GUIDE detection: show highlight as soon as we parse coordinates
                    if !highlightShown, let guide = parseGuideResponse(streamedText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        highlightShown = true
                        if guide.x > 0 || guide.y > 0 {
                            // Scale from API coordinates to logical screen coordinates
                            let scaledX = Int(Double(guide.x) * executor.scaleX)
                            let scaledY = Int(Double(guide.y) * executor.scaleY)
                            capturedOverlay?.showHighlight(x: scaledX, y: scaledY)
                            capturedOverlay?.setState(.guiding, detail: "Look here")
                        } else {
                            capturedOverlay?.setState(.guiding, detail: "Keyboard")
                        }
                    }

                    // Streaming narration: only speak the FIRST sentence if it's a NARRATE: line.
                    // Skip DONE:/CLARIFY:/GUIDE: — those have their own narration paths.
                    if let nq = capturedNarrationQueue, !firstSentenceStreamed {
                        let trimmedStream = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Don't stream-narrate DONE/CLARIFY/GUIDE — they get narrated elsewhere
                        if trimmedStream.hasPrefix("DONE:") || trimmedStream.hasPrefix("CLARIFY:") || trimmedStream.hasPrefix("GUIDE:") {
                            firstSentenceStreamed = true  // block further streaming narration
                        } else if let endIdx = findSentenceBoundary(sentenceBuffer) {
                            var sentence = String(sentenceBuffer[..<endIdx]).trimmingCharacters(in: .whitespaces)
                            sentenceBuffer = String(sentenceBuffer[endIdx...])
                            firstSentenceStreamed = true
                            sentence = stripNarratePrefix(sentence)
                            if !sentence.isEmpty {
                                nq.enqueue(sentence)
                            }
                        }
                    }
                }
            )
            let modelLabel = model.rawValue.split(separator: "-").prefix(2).joined(separator: "-")
            logger.log("[\(modelLabel) #\(iterations)] stop: \(response.stopReason ?? "nil")")

            history.append(Message(role: "assistant", content: response.content))

            // Extract text and tool uses from response
            var toolUses: [ToolUseBlock] = []
            var textOutput = ""
            for block in response.content {
                switch block {
                case .text(let text):
                    if !text.isEmpty {
                        logger.log("SONNET: \(text)")
                        textOutput += text
                    }
                case .toolUse(let toolUse):
                    toolUses.append(toolUse)
                default:
                    break
                }
            }

            // Check for signals anywhere in text (Sonnet often puts text before the prefix)
            let trimmedText = textOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            // Find DONE: anywhere in the text
            if let doneRange = trimmedText.range(of: "DONE:") {
                let summary = String(trimmedText[doneRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                logger.log("[sonnet-direct] DONE after \(iterations) iterations: \(summary)")
                overlay?.hideHighlight()
                return .done(summary.isEmpty ? "Task completed." : summary)
            }

            // Find CLARIFY: anywhere — extract just the question part
            if let clarifyRange = trimmedText.range(of: "CLARIFY:") {
                let question = String(trimmedText[clarifyRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                logger.log("[sonnet-direct] CLARIFY after \(iterations) iterations: \(question)")
                overlay?.hideHighlight()
                return .clarify(question.isEmpty ? "Could you provide more details?" : question)
            }

            // Find GUIDE: anywhere in text — parse the last occurrence
            if let guideRange = trimmedText.range(of: "GUIDE:", options: .backwards) {
                let guideText = "GUIDE:" + String(trimmedText[guideRange.upperBound...])
                if let guide = parseGuideResponse(guideText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    logger.log("[guide] (\(guide.x), \(guide.y)) \(guide.instruction)")
                    print("[Guide] \(guide.instruction)")

                    // Show highlight circle (skip for 0,0 which means keyboard-only instruction)
                    if guide.x > 0 || guide.y > 0 {
                        // Scale from API coordinates to logical screen coordinates
                        let scaledX = Int(Double(guide.x) * executor.scaleX)
                        let scaledY = Int(Double(guide.y) * executor.scaleY)
                        overlay?.showHighlight(x: scaledX, y: scaledY)
                        overlay?.setState(.guiding, detail: "Look here")
                    } else {
                        overlay?.hideHighlight()
                        overlay?.setState(.guiding, detail: "Keyboard")
                    }

                    // Narrate the instruction (non-blocking — speaks while we wait)
                    if let nq = narrationQueue {
                        nq.enqueue(guide.instruction)
                    } else if let voice = voice {
                        await voice.speakAndWait(guide.instruction)
                    }

                    // Wait for user to act — 1.5s (was 3s + TTS time, now TTS plays in parallel)
                    try await Task.sleep(nanoseconds: 1_500_000_000)

                    overlay?.hideHighlight()

                    // Take fresh screenshot to see what user did
                    if let (newScreenshot, _, _, _, _) = screenshotBase64() {
                        let newImageSource = ImageSource(type: "base64", mediaType: "image/jpeg", data: newScreenshot)
                        history.append(Message(role: "user", content: [
                            .image(newImageSource),
                            .text("The user was guided. Here is the current screen. Continue helping.")
                        ]))
                    } else {
                        return .done("Lost screen access.")
                    }
                    continue
                }
            }

            let hasToolUse = !toolUses.isEmpty

            if hasToolUse {
                // Show .narrating when TTS is playing alongside actions, otherwise .acting
                if let nq = narrationQueue, (nq.isActive || firstSentenceStreamed) {
                    overlay?.setState(.narrating)
                } else {
                    overlay?.setState(.acting)
                }

                // Skip stale queued narration — actions may have moved ahead
                narrationQueue?.skipStale()

                let batchStart = ContinuousClock.now
                for (i, toolUse) in toolUses.enumerated() {
                    if Task.isCancelled { return .done("Cancelled.") }
                    if let action = ComputerAction(from: toolUse.input) {
                        logger.log("[action \(i+1)/\(toolUses.count)] \(action)")
                        await executor.execute(action)
                        try await Task.sleep(nanoseconds: 200_000_000)

                        switch action {
                        case .leftClick(let x, let y), .doubleClick(let x, let y), .rightClick(let x, let y):
                            recentClicks.append((x: x, y: y))
                        case .type:
                            recentClicks.removeAll()
                        default:
                            break
                        }
                    }
                }

                try await Task.sleep(nanoseconds: 300_000_000)
                let batchDuration = ContinuousClock.now - batchStart
                logger.log("[batch \(toolUses.count) actions] \(batchDuration)")

                // After the first action batch, maximize the now-focused window.
                // This ensures we maximize Chrome/Safari/etc., not Terminal.
                if !didMaximize {
                    didMaximize = true
                    executor.maximizeFrontWindow()
                    try await Task.sleep(nanoseconds: 200_000_000) // let animation settle
                }

                let repeatWarning = checkForRepeatedClicks(recentClicks, threshold: repeatThreshold)
                if repeatWarning != nil {
                    recentClicks.removeAll()
                }

                // Screenshot after batch (and after maximize)
                if let (newScreenshot, _, _, _, _) = screenshotBase64() {
                    let newImageSource = ImageSource(type: "base64", mediaType: "image/jpeg", data: newScreenshot)

                    var toolResultBlocks: [ContentBlock] = []
                    for (i, toolUse) in toolUses.enumerated() {
                        let actionDesc = ComputerAction(from: toolUse.input).map { actionDescription($0) } ?? toolUse.input.action
                        if i == toolUses.count - 1 {
                            var resultContent: [ContentBlock] = [
                                .text("Action executed: \(actionDesc)"),
                                .image(newImageSource)
                            ]
                            if let warning = repeatWarning {
                                resultContent.append(.text(warning))
                                logger.log("[repeat warning] \(warning)")
                            }
                            toolResultBlocks.append(.toolResult(ToolResultBlock(
                                toolUseId: toolUse.id,
                                content: resultContent
                            )))
                        } else {
                            toolResultBlocks.append(.toolResult(ToolResultBlock(
                                toolUseId: toolUse.id,
                                content: [.text("Action executed: \(actionDesc)")]
                            )))
                        }
                    }
                    history.append(Message(role: "user", content: toolResultBlocks))
                } else {
                    return .done("Lost screen access.")
                }
            }

            if response.stopReason == "tool_use" && hasToolUse {
                continue
            } else if !hasToolUse {
                // Sonnet responded with conversational text (no prefix, no tools).
                // If it's a question, treat as clarification so the answer gets
                // routed back through the bridge and re-run with context.
                logger.log("[sonnet-direct] conversational response after \(iterations) iterations")
                overlay?.hideHighlight()
                let responseText = trimmedText.isEmpty ? "Task completed." : trimmedText
                if trimmedText.contains("?") {
                    // Question — treat as clarification so user's answer feeds back
                    return .clarify(responseText)
                }
                return .done(responseText)
            } else {
                overlay?.hideHighlight()
                return .done("Task completed.")
            }

        } catch {
            logger.log("[sonnet-direct error] \(error)")
            overlay?.hideHighlight()
            return .escalate
        }
    }

    logger.log("[sonnet-direct] hit iteration limit (\(maxIterations))")
    overlay?.hideHighlight()
    return .escalate
}

/// Fast-path entry point: Sonnet handles the task directly, escalates to Opus only on failure.
func fastPathExecute(
    userInput: String,
    screenshotData: String,
    orchestrator: Orchestrator,
    client: AnthropicClient,
    executor: ActionExecutor,
    logger: SessionLogger,
    sonnetPrompt: String,
    sonnetDirectPrompt: String,
    maxIterationsPerBlock: Int,
    maxReplans: Int,
    maxDirectIterations: Int,
    overlay: OverlayManager? = nil,
    voice: VoiceManager? = nil,
    narrationQueue: NarrationQueue? = nil,
    clarificationBridge: ClarificationBridge? = nil,
    sessionContext: String? = nil
) async -> String {
    logger.log("[fast-path] starting sonnet-direct")
    print("[Fast-path] Sonnet handling task directly")

    // Detect guidance trigger phrases — force GUIDE mode when user asks to be shown/helped/taught
    let lowerInput = userInput.lowercased()
    let guidanceTriggers = ["show me", "help me", "teach me", "walk me through", "how do i"]
    let forceGuide = guidanceTriggers.contains(where: { lowerInput.contains($0) })
    var effectivePrompt = sonnetDirectPrompt
    if forceGuide {
        effectivePrompt += "\n\nIMPORTANT: The user wants to be GUIDED, not have actions done for them. Use GUIDE mode EXCLUSIVELY. Do NOT take any actions or make tool calls. Only respond with GUIDE: instructions, one step at a time. Point at specific UI elements on screen and tell the user what to click or type. Be patient and encouraging."
        logger.log("[fast-path] GUIDE mode forced — trigger detected in: \(userInput)")
    }

    let result = await runSonnetDirect(
        userRequest: userInput,
        screenshotData: screenshotData,
        client: client,
        executor: executor,
        logger: logger,
        systemPrompt: effectivePrompt,
        maxIterations: maxDirectIterations,
        overlay: overlay,
        voice: voice,
        narrationQueue: narrationQueue,
        sessionContext: sessionContext
    )

    switch result {
    case .done(let summary):
        logger.log("[fast-path] done: \(summary)")
        return summary

    case .clarify(let question):
        logger.log("[fast-path] clarification needed: \(question)")
        // In voice mode, ask via TTS and wait for answer
        if let voice = voice, let bridge = clarificationBridge {
            bridge.markPending()
            overlay?.setState(.speaking)
            await voice.speakAndWait(question)
            overlay?.setState(.listening, detail: "Clarifying")
            if let answer = await bridge.waitForAnswer() {
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return "No clarification provided."
                }
                logger.log("[fast-path] clarification answer: \(trimmed)")
                // Re-run Sonnet with enriched input
                let enrichedInput = "\(userInput) (User clarified: \(trimmed))"
                guard let (ss2, _, _, _, _) = screenshotBase64() else { return "Lost screen access." }
                let retryResult = await runSonnetDirect(
                    userRequest: enrichedInput,
                    screenshotData: ss2,
                    client: client,
                    executor: executor,
                    logger: logger,
                    systemPrompt: sonnetDirectPrompt,
                    maxIterations: maxDirectIterations,
                    overlay: overlay,
                    voice: voice,
                    narrationQueue: narrationQueue,
                    sessionContext: sessionContext
                )
                switch retryResult {
                case .done(let summary): return summary
                case .clarify(let q2):
                    logger.log("[fast-path] second clarification, escalating: \(q2)")
                    // Fall through to Opus escalation
                case .escalate:
                    break
                }
            }
        } else {
            // Text mode — print the question, but can't easily get answer mid-run
            // Escalate to Opus which has its own clarification mechanism
            print("[Clarification needed] \(question)")
        }
        // Escalate
        logger.log("[fast-path] escalating to opus pipeline")
        print("[Fast-path] Escalating to Opus pipeline")
        return await planAndExecute(
            userInput: userInput,
            screenshotData: screenshotData,
            orchestrator: orchestrator,
            client: client,
            executor: executor,
            logger: logger,
            sonnetPrompt: sonnetPrompt,
            maxIterationsPerBlock: maxIterationsPerBlock,
            maxReplans: maxReplans,
            overlay: overlay,
            voice: voice,
            clarificationBridge: clarificationBridge
        )

    case .escalate:
        logger.log("[fast-path] sonnet hit limit, escalating to opus pipeline")
        print("[Fast-path] Sonnet hit limit, escalating to Opus pipeline")
        guard let (ss, _, _, _, _) = screenshotBase64() else { return "Lost screen access." }
        return await planAndExecute(
            userInput: userInput,
            screenshotData: ss,
            orchestrator: orchestrator,
            client: client,
            executor: executor,
            logger: logger,
            sonnetPrompt: sonnetPrompt,
            maxIterationsPerBlock: maxIterationsPerBlock,
            maxReplans: maxReplans,
            overlay: overlay,
            voice: voice,
            clarificationBridge: clarificationBridge
        )
    }
}

// MARK: - Shared: plan and execute (Opus pipeline — used as escalation fallback)

/// Plan a pipeline and execute it. Returns summary string.
/// If clarifications are needed, asks via voice in parallel with executing initial blocks.
func planAndExecute(
    userInput: String,
    screenshotData: String,
    orchestrator: Orchestrator,
    client: AnthropicClient,
    executor: ActionExecutor,
    logger: SessionLogger,
    sonnetPrompt: String,
    maxIterationsPerBlock: Int,
    maxReplans: Int,
    overlay: OverlayManager? = nil,
    voice: VoiceManager? = nil,
    clarificationBridge: ClarificationBridge? = nil
) async -> String {
    // Opus plans the pipeline
    overlay?.setState(.thinking, detail: "Planning")
    let plan: Orchestrator.PipelineResponse
    do {
        plan = try await orchestrator.planPipeline(
            userRequest: userInput,
            screenshotBase64: screenshotData
        )
    } catch {
        logger.log("[opus plan error] \(error)")
        // Fallback: single block with raw user input
        let fallbackBlock = Orchestrator.WorkBlock(
            directive: userInput,
            expectedOutcome: "The user's request has been fulfilled"
        )
        return await executePipeline(
            userInput: userInput,
            blocks: [fallbackBlock],
            orchestrator: orchestrator,
            client: client,
            executor: executor,
            logger: logger,
            sonnetPrompt: sonnetPrompt,
            maxIterationsPerBlock: maxIterationsPerBlock,
            maxReplans: maxReplans,
            overlay: overlay
        )
    }

    // Log the plan
    print("[Plan] \(plan.blocks.count) blocks:")
    for (i, block) in plan.blocks.enumerated() {
        print("  \(i + 1). \(block.directive)")
        print("     -> \(block.expectedOutcome)")
    }
    if !plan.clarifications.isEmpty {
        print("[Clarifying] \(plan.clarifications.joined(separator: " | "))")
    }
    print("")

    // Start clarification Q&A in parallel with block execution (voice mode only)
    // Questions are asked one at a time — each waits for an answer before the next
    var answerTask: Task<String?, Never>? = nil
    if !plan.clarifications.isEmpty, let voice = voice, let bridge = clarificationBridge {
        let questions = plan.clarifications
        logger.log("[clarification] \(questions.count) questions to ask")
        answerTask = Task {
            var answers: [String] = []
            for (i, question) in questions.enumerated() {
                logger.log("[clarification \(i+1)/\(questions.count)] asking: \(question)")
                bridge.markPending()
                await voice.speakAndWait(question) // TTS finishes, then voice loop listens
                guard let answer = await bridge.waitForAnswer() else { return nil } // cancelled
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                answers.append(trimmed)
                logger.log("[clarification \(i+1)] answer: \(trimmed)")
                // Brief pause between questions for natural pacing
                if i < questions.count - 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            return answers.isEmpty ? nil : answers.joined(separator: ". ")
        }
    }

    // If clarifications exist, don't execute the last block — it almost always
    // depends on the user's answer. It will be properly planned by
    // replanWithClarification after the answer arrives.
    var executableBlocks = plan.blocks
    if !plan.clarifications.isEmpty && plan.blocks.count > 1 {
        executableBlocks = Array(plan.blocks.dropLast())
        logger.log("[clarification] truncated \(plan.blocks.count) blocks to \(executableBlocks.count) — last block depends on answers")
        print("[Clarification] Running \(executableBlocks.count) setup blocks while asking questions")
    }

    // Execute the blocks that can run without clarification answers
    var summary = "Nothing yet"
    if !executableBlocks.isEmpty {
        summary = await executePipeline(
            userInput: userInput,
            blocks: executableBlocks,
            orchestrator: orchestrator,
            client: client,
            executor: executor,
            logger: logger,
            sonnetPrompt: sonnetPrompt,
            maxIterationsPerBlock: maxIterationsPerBlock,
            maxReplans: maxReplans,
            overlay: overlay
        )
    }

    // If clarifications were asked, wait for answers and continue with remaining work
    if let answerTask = answerTask {
        logger.log("[clarification] waiting for answer...")
        overlay?.setState(.listening, detail: "Clarifying")

        if let answer = await answerTask.value {
            logger.log("[clarification] got answer: \(answer)")

            guard let (freshSS, _, _, _, _) = screenshotBase64() else {
                return summary
            }

            do {
                overlay?.setState(.thinking, detail: "Replanning")
                let newBlocks = try await orchestrator.replanWithClarification(
                    originalRequest: userInput,
                    clarificationAnswers: answer,
                    accomplishedSoFar: summary,
                    screenshotBase64: freshSS
                )
                logger.log("[clarification replan] \(newBlocks.count) blocks")
                print("[Clarification plan] \(newBlocks.count) blocks:")
                for (i, b) in newBlocks.enumerated() {
                    logger.log("[clarification block \(i+1)] \(b.directive)")
                    print("  \(i + 1). \(b.directive)")
                }

                if !newBlocks.isEmpty {
                    summary = await executePipeline(
                        userInput: "\(userInput) (\(answer))",
                        blocks: newBlocks,
                        orchestrator: orchestrator,
                        client: client,
                        executor: executor,
                        logger: logger,
                        sonnetPrompt: sonnetPrompt,
                        maxIterationsPerBlock: maxIterationsPerBlock,
                        maxReplans: maxReplans,
                        overlay: overlay,
                        clarificationAnswer: answer
                    )
                }
            } catch {
                logger.log("[clarification replan error] \(error)")
            }
        } else {
            logger.log("[clarification] no answer (cancelled)")
        }
    }

    return summary
}

// MARK: - Opus Voice Intent (Phase 3)

/// Parsed intent from Opus interpretation of raw voice input.
struct VoiceIntent: Sendable {
    let type: String       // "command" | "followup" | "interrupt" | "chat" | "memory"
    let directive: String  // Refined directive for action model
    let response: String?  // Immediate spoken response
    let remember: String?  // Fact to store in memory
}

/// Check if voice input can bypass Opus intent interpretation.
/// Aggressively returns true — only routes through Opus for clearly conversational/ambiguous input.
/// This saves ~2.3s per turn for most commands.
func isSimpleCommand(_ input: String) -> Bool {
    let lower = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    // Questions need Opus
    if lower.hasSuffix("?") { return true }  // Even questions go direct — Haiku handles them via CLARIFY:

    // These phrases indicate conversational/contextual input that benefits from Opus
    let needsOpus = ["actually", "instead", "rather", "hmm",
                     "what did", "what was", "what were", "what are",
                     "how did", "how was", "why did", "why was",
                     "remember that", "always use", "i prefer", "i like to",
                     "tell me about", "explain what"]
    if needsOpus.contains(where: { lower.contains($0) }) { return false }

    // Everything else bypasses Opus — direct to action model
    return true
}

// MARK: - Speculative Similarity Functions

/// Normalize text to tokens for comparison: lowercase, strip punctuation, remove stopwords.
func normalizeTokens(_ input: String) -> [String] {
    let stopwords: Set<String> = ["the", "a", "an", "please", "can", "you", "could", "would"]
    return input.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty && !stopwords.contains($0) }
}

/// Levenshtein edit distance between two strings.
func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1)
    let b = Array(s2)
    let m = a.count, n = b.count

    if m == 0 { return n }
    if n == 0 { return m }

    var prev = Array(0...n)
    var curr = [Int](repeating: 0, count: n + 1)

    for i in 1...m {
        curr[0] = i
        for j in 1...n {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        }
        prev = curr
    }
    return prev[n]
}

/// Check if a speculative partial transcript is similar enough to the final transcript.
/// Uses normalized tokens with multi-tier matching:
/// 1. Exact token match
/// 2. Prefix token match (>= 2 tokens)
/// 3. Short command template match (verb + edit distance <= 1)
/// 4. Levenshtein on joined tokens < 15%
func isSimilar(_ specInput: String, _ finalInput: String) -> Bool {
    let specTokens = normalizeTokens(specInput)
    let finalTokens = normalizeTokens(finalInput)

    // Reject if final is much shorter (user restarted sentence)
    guard finalTokens.count >= max(specTokens.count - 1, 2) else { return false }

    // Gate 1: command class must agree
    guard isSimpleCommand(specInput) == isSimpleCommand(finalInput) else { return false }

    // Gate 2: for short commands, first token must be a known command verb
    let commandVerbs: Set<String> = [
        "open", "go", "click", "search", "find", "type", "close", "switch",
        "tab", "run", "show", "hide", "scroll", "select", "copy", "paste",
        "delete", "send", "reply", "forward", "navigate", "maximize", "minimize"
    ]
    if specTokens.count <= 3 || finalTokens.count <= 3 {
        guard let specVerb = specTokens.first, let finalVerb = finalTokens.first,
              commandVerbs.contains(specVerb), commandVerbs.contains(finalVerb) else {
            return false
        }
    }

    // Tier 1: exact token match
    if specTokens == finalTokens { return true }

    // Tier 2: first N tokens match (N = specTokens.count, min 2)
    let matchCount = min(specTokens.count, finalTokens.count)
    if matchCount >= 2 && Array(specTokens.prefix(matchCount)) == Array(finalTokens.prefix(matchCount)) {
        return true
    }

    // Tier 3: Short command template match
    if specTokens.count == finalTokens.count &&
       specTokens.count >= 2 && specTokens.count <= 3 &&
       specTokens[0] == finalTokens[0] {
        if specTokens.count == 2 {
            if levenshteinDistance(specTokens[1], finalTokens[1]) <= 1 { return true }
        } else { // count == 3
            if specTokens[1] == finalTokens[1] &&
               levenshteinDistance(specTokens[2], finalTokens[2]) <= 1 { return true }
        }
    }

    // Tier 4: Levenshtein on joined tokens < 15%
    let specJoined = specTokens.joined(separator: " ")
    let finalJoined = finalTokens.joined(separator: " ")
    let maxLen = max(specJoined.count, finalJoined.count)
    if maxLen > 0 {
        let dist = levenshteinDistance(specJoined, finalJoined)
        if Double(dist) / Double(maxLen) < 0.15 { return true }
    }

    return false
}

/// Clean common STT transcription errors, especially around email addresses.
/// Apple's SFSpeechRecognizer often inserts spaces in email addresses:
/// "Arora 710@gmail.com" → "Arora710@gmail.com"
func cleanSTTOutput(_ text: String) -> String {
    guard text.contains("@") else { return text }
    var result = text
    // Remove spaces directly before @: "user @gmail" → "user@gmail"
    result = result.replacingOccurrences(of: #"\s+@"#, with: "@", options: .regularExpression)
    // Remove spaces directly after @: "user@ gmail" → "user@gmail"
    result = result.replacingOccurrences(of: #"@\s+"#, with: "@", options: .regularExpression)
    // Collapse space between letters and digits before @: "Arora 710@" → "Arora710@"
    result = result.replacingOccurrences(of: #"([a-zA-Z])\s+(\d+@)"#, with: "$1$2", options: .regularExpression)
    // Collapse space between digits and letters before @: "710 arora@" → "710arora@"
    result = result.replacingOccurrences(of: #"(\d)\s+([a-zA-Z]+@)"#, with: "$1$2", options: .regularExpression)
    return result
}

/// Random filler phrase for immediate acknowledgment while API call runs.
func randomFiller() -> String {
    let fillerPhrases = ["On it.", "Sure.", "Let me do that.", "Got it.", "One moment."]
    return fillerPhrases.randomElement()!
}

/// Lightweight Opus call to interpret raw voice input.
/// Returns structured intent: what to do, what to say, what to remember.
func interpretVoiceInput(
    rawSpeech: String,
    sessionContext: String?,
    memory: String?,
    client: AnthropicClient,
    logger: SessionLogger
) async -> VoiceIntent? {
    let systemPrompt = """
    You are interpreting a voice command for a computer-use agent.
    Given the raw speech and conversation context, determine the user's intent.

    Respond with ONLY a JSON object:
    {
      "type": "command" | "followup" | "interrupt" | "chat" | "memory",
      "directive": "refined directive for the action model",
      "response": "brief spoken acknowledgment (optional, 1 sentence max)",
      "remember": "fact to store about user preferences (optional)"
    }

    Types:
    - "command": new task to execute (directive = what to do)
    - "followup": modifies the previous task (directive = updated instruction using context)
    - "interrupt": cancel current action
    - "chat": conversational, no action needed (response = your reply)
    - "memory": user stated a preference (remember = the fact, response = acknowledgment)

    Keep response under 10 words. Keep directive specific and actionable.
    If the input is a clear command, just pass it through with minimal rewording.
    """

    var contextParts: [String] = []
    if let ctx = sessionContext, !ctx.isEmpty {
        contextParts.append("Conversation so far:\n\(ctx)")
    }
    if let mem = memory, !mem.isEmpty {
        contextParts.append("Known user preferences:\n\(mem)")
    }
    contextParts.append("User said: \"\(rawSpeech)\"")

    let messages = [Message(role: "user", content: [.text(contextParts.joined(separator: "\n\n"))])]

    do {
        let response = try await client.sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            model: .opus
        )

        var fullText = ""
        for block in response.content {
            if case .text(let text) = block { fullText += text }
        }

        // Parse JSON
        var jsonText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```json") { jsonText = String(jsonText.dropFirst(7)) }
        if jsonText.hasPrefix("```") { jsonText = String(jsonText.dropFirst(3)) }
        if jsonText.hasSuffix("```") { jsonText = String(jsonText.dropLast(3)) }
        jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON object in text
        if !jsonText.hasPrefix("{") {
            if let start = jsonText.firstIndex(of: "{"),
               let end = jsonText.lastIndex(of: "}") {
                jsonText = String(jsonText[start...end])
            }
        }

        guard let data = jsonText.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = parsed["type"] as? String else {
            logger.log("[opus-intent] failed to parse: \(fullText)")
            return nil
        }

        let intent = VoiceIntent(
            type: type,
            directive: (parsed["directive"] as? String) ?? rawSpeech,
            response: parsed["response"] as? String,
            remember: parsed["remember"] as? String
        )
        logger.log("[opus-intent] type=\(intent.type) directive=\(intent.directive)")
        return intent
    } catch {
        logger.log("[opus-intent error] \(error)")
        return nil
    }
}

// MARK: - Voice Mode

func runVoiceMode(
    orchestrator: Orchestrator,
    client: AnthropicClient,
    executor: ActionExecutor,
    logger: SessionLogger,
    sonnetPrompt: String,
    sonnetDirectPrompt: String,
    maxIterationsPerBlock: Int,
    maxReplans: Int,
    maxDirectIterations: Int,
    overlay: OverlayManager
) async {
    let voice = VoiceManager(logger: logger)
    let narrationQueue = NarrationQueue(voice: voice.ttsVoice, logger: logger)
    voice.narrationQueue = narrationQueue
    let clarificationBridge = ClarificationBridge()
    let memoryStore = MemoryStore(logger: logger)

    print("CUA - Computer Use Agent (Voice Mode)")
    print("Requesting permissions...")

    guard await voice.requestPermissions() else {
        print("Cannot start voice mode without microphone and speech recognition permissions.")
        return
    }

    // Setup STT provider (WhisperKit if enabled, else Apple STT)
    // Must happen AFTER permissions are granted — WhisperKit may access mic during setup
    await voice.setupSTT()

    print("Voice mode active. Speak commands naturally.")
    print("Say 'stop' to cancel, 'quit' to exit.")
    print("")
    await voice.speakAndWait("Ready.")

    var actionTask: Task<Void, Never>?
    var actionCompletion: TaskCompletionBox?
    let perfTracker = PerfTracker()
    let specBox = SpeculativeCallBox()
    var speculativeEnabled = featureEnabled("CUA_USE_SPECULATIVE")
    var specHits = 0
    var specMisses = 0

    // Rolling session context — keeps Sonnet aware of the conversation across voice turns.
    // Each turn appends "User: <request> → Agent: <summary>" so the next turn has full context.
    // Thread-safe because the Task closure needs to append to it.
    let sessionContext = SessionContext()
    var pendingInterrupt: String? = nil  // Speech captured during action — process without re-listening

    while true {
        let userInput: String
        let screenshotBox = ScreenshotBox()
        let currentUtteranceId = nextUtteranceId()

        if let pending = pendingInterrupt {
            // Re-process interrupted speech without calling listen()
            pendingInterrupt = nil
            userInput = pending
            narrationQueue.unmute()
            // Pre-capture screenshot for the interrupted command
            if let (ss, _, _, _, _) = screenshotBase64() {
                screenshotBox.data = ss
            }
            logger.log("[voice-interrupt] processing: \(userInput)")
            print("[Interrupt] \"\(userInput)\"")
        } else {
            print("Listening...")
            overlay.setState(.listening)

            // Pre-capture screenshot while user is still finishing their sentence.
            // onStablePartial fires when partial text hasn't changed for 500ms,
            // overlapping screenshot capture with the silence timeout.
            specBox.reset(utteranceId: currentUtteranceId)

            // Capture refs for use in onStablePartial closure
            let capturedSpecEnabled = speculativeEnabled
            let capturedClient = client
            let capturedSonnetDirectPrompt = sonnetDirectPrompt
            let capturedLogger = logger

            guard let rawUserInput = await voice.listen(onStablePartial: { partialText in
                // Pre-capture screenshot (existing behavior)
                if let (ss, _, _, _, _) = screenshotBase64() {
                    screenshotBox.data = ss
                }

                // Fire speculative API call if enabled and partial looks like a command
                let words = partialText.split(separator: " ")
                if capturedSpecEnabled && words.count >= 2 && isSimpleCommand(partialText),
                   let ss = screenshotBox.data {
                    specBox.fire(input: partialText, screenshot: ss, utteranceId: currentUtteranceId) { input, screenshot in
                        // This closure runs the actual API call
                        capturedLogger.log("[perf:U\(currentUtteranceId)] speculative_fire: \(input)")
                        do {
                            let result = try await capturedClient.streamMessage(
                                messages: [Message(role: "user", content: [
                                    .image(ImageSource(type: "base64", mediaType: "image/jpeg", data: screenshot)),
                                    .text(input)
                                ])],
                                systemPrompt: capturedSonnetDirectPrompt,
                                model: .haiku,
                                onTextDelta: { _ in }
                            )
                            // Extract tool calls and text
                            var toolCalls: [ToolUseBlock] = []
                            var textOutput = ""
                            for block in result.content {
                                switch block {
                                case .text(let text): textOutput += text
                                case .toolUse(let tu): toolCalls.append(tu)
                                default: break
                                }
                            }
                            return (toolCalls: toolCalls, textOutput: textOutput)
                        } catch {
                            capturedLogger.log("[speculative error] \(error)")
                            return nil
                        }
                    }
                }
            }) else {
                narrationQueue.unmute()  // re-enable narration after listen
                continue
            }

            // Unmute narration now that mic is closed — action tasks can speak again
            narrationQueue.unmute()

            // Clean STT output — fix common transcription errors (email spaces, etc.)
            userInput = cleanSTTOutput(rawUserInput)
        }

        // Filter out empty/whitespace-only transcriptions (happens when TTS interrupts mic)
        guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
        }

        let requestStart = ContinuousClock.now
        let utteranceId = nextUtteranceId()
        let perfGuard = UtterancePerfGuard(id: utteranceId, startTime: requestStart, logger: logger, tracker: perfTracker)
        logger.logSeparator()
        logger.log("VOICE: \(userInput) [U\(utteranceId)]")
        print("[Voice] \"\(userInput)\"")

        let lower = userInput.lowercased()

        if lower.contains("quit") || lower.contains("goodbye") || lower == "exit" {
            clarificationBridge.cancel()
            actionTask?.cancel()
            voice.stopSpeaking()
            logger.log("[perf] session summary: \(perfTracker.summary())")
            print("[Perf] \(perfTracker.summary())")
            perfGuard.emitNoAction(reason: "quit")
            await voice.speakAndWait("Goodbye!")
            break
        }

        if lower == "stop" || lower == "cancel" || lower == "never mind" {
            clarificationBridge.cancel()
            narrationQueue.cancelAll()
            if actionTask != nil {
                actionTask?.cancel()
                actionTask = nil
                voice.stopSpeaking()
                voice.speak("Cancelled.")
                logger.log("[cancelled by voice]")
                print("[Cancelled]")
            } else {
                voice.speak("Nothing to cancel.")
            }
            perfGuard.emitNoAction(reason: "cancelled")
            continue
        }

        // Route clarification answers to the pending bridge
        if clarificationBridge.isPending {
            logger.log("[clarification answer] \(userInput)")
            print("[Clarification] \"\(userInput)\"")
            clarificationBridge.provideAnswer(userInput)
            perfGuard.emitNoAction(reason: "clarification")
            continue
        }

        // Cancel any running action
        if let prevTask = actionTask {
            prevTask.cancel()
            voice.stopSpeaking()
            actionTask = nil
            logger.log("[interrupted by new command]")
        }

        // Add this turn's user message to context
        sessionContext.addUserTurn(userInput)

        // Opus intent routing: simple commands bypass Opus, complex/conversational go through it
        if isSimpleCommand(userInput) {
            // Fast path: skip Opus, go straight to action model
            logger.log("[intent] simple command, bypassing Opus")

            // Filler audio — immediate acknowledgment (preemptible by real narration)
            narrationQueue.enqueue(randomFiller())
            logger.log("[perf:U\(utteranceId)] filler_start")

            // Use pre-captured screenshot if available (saves ~100ms)
            let screenshotData: String
            if let preCaptured = screenshotBox.data {
                screenshotData = preCaptured
                logger.log("[pipeline] using pre-captured screenshot")
            } else {
                guard let (ss, _, _, _, _) = screenshotBase64() else {
                    await voice.speakAndWait("I can't capture the screen.")
                    continue
                }
                screenshotData = ss
            }

            // Check speculative result — single authority: speculative OR normal, never both
            // Only accept speculative results that produced actual tool calls (actions).
            // A result with zero tool calls means the partial text was too ambiguous — treat as miss.
            if let spec = await specBox.claimResult(finalText: userInput, utteranceId: currentUtteranceId, similarityCheck: isSimilar),
               !spec.toolCalls.isEmpty {
                // Speculative hit — use pre-computed result
                specHits += 1
                logger.log("[perf:U\(utteranceId)] speculative_hit")
                perfGuard.emitAction(source: "speculative")

                // Preempt filler with real narration
                let narrationText = spec.textOutput.isEmpty ? "Done." : stripNarratePrefix(spec.textOutput)
                narrationQueue.interruptAndEnqueue(narrationText)

                // Execute tool calls from speculative result
                overlay.setState(.acting)
                let specCompletion = TaskCompletionBox()
                actionCompletion = specCompletion
                actionTask = Task {
                    defer { specCompletion.markDone() }
                    for toolUse in spec.toolCalls {
                        if Task.isCancelled { break }
                        if let action = ComputerAction(from: toolUse.input) {
                            logger.log("[speculative action] \(action)")
                            await executor.execute(action)
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                    }
                    let totalDuration = ContinuousClock.now - requestStart
                    print("[Done] (\(totalDuration)) \(narrationText) (speculative)")
                    logger.log("[done] \(totalDuration) | \(narrationText) (speculative)")
                    sessionContext.addAgentTurn(narrationText)
                }
            } else {
                // Speculative miss or not ready — cancel and run normal path
                if speculativeEnabled {
                    specMisses += 1
                    logger.log("[perf:U\(utteranceId)] speculative_miss")
                }
                await specBox.cancel()

                // Runtime kill-switch: auto-disable if hit rate too low
                if specMisses > 5 && specHits == 0 {
                    speculativeEnabled = false
                    logger.log("[perf] speculative auto-disabled: \(specMisses) misses, 0 hits")
                }
                if (specHits + specMisses) >= 10 {
                    let hitRate = Double(specHits) / Double(specHits + specMisses)
                    if hitRate < 0.3 {
                        speculativeEnabled = false
                        logger.log("[perf] speculative auto-disabled: hit rate \(Int(hitRate * 100))%")
                    }
                }

                overlay.setState(.thinking)
                let capturedInput = userInput
                let capturedScreenshot = screenshotData
                let capturedContext = sessionContext.getContextWithMemory(memoryStore.asPromptContext())
                let normalCompletion = TaskCompletionBox()
                actionCompletion = normalCompletion
                actionTask = Task {
                    defer { normalCompletion.markDone() }
                    let summary = await fastPathExecute(
                        userInput: capturedInput,
                        screenshotData: capturedScreenshot,
                        orchestrator: orchestrator,
                        client: client,
                        executor: executor,
                        logger: logger,
                        sonnetPrompt: sonnetPrompt,
                        sonnetDirectPrompt: sonnetDirectPrompt,
                        maxIterationsPerBlock: maxIterationsPerBlock,
                        maxReplans: maxReplans,
                        maxDirectIterations: maxDirectIterations,
                        overlay: overlay,
                        voice: voice,
                        narrationQueue: narrationQueue,
                        clarificationBridge: clarificationBridge,
                        sessionContext: capturedContext
                    )

                    let totalDuration = ContinuousClock.now - requestStart
                    print("[Done] (\(totalDuration)) \(summary)")
                    logger.log("[done] \(totalDuration) | \(summary)")

                    sessionContext.addAgentTurn(summary)

                    if !Task.isCancelled {
                        overlay.setState(.speaking)
                        // Preempt filler with real summary narration
                        narrationQueue.interruptAndEnqueue(summary)
                    }
                }
            }
        } else {
            // Complex/conversational: route through Opus for intent interpretation
            overlay.setState(.understanding)
            logger.log("[intent] routing through Opus")

            let capturedContext = sessionContext.getContext()
            let memoryContext = memoryStore.asPromptContext()
            let capturedInput = userInput
            let opusCompletion = TaskCompletionBox()
            actionCompletion = opusCompletion

            actionTask = Task {
                defer { opusCompletion.markDone() }
                let intent = await interpretVoiceInput(
                    rawSpeech: capturedInput,
                    sessionContext: capturedContext,
                    memory: memoryContext,
                    client: client,
                    logger: logger
                )

                guard let intent = intent else {
                    // Opus failed — fall back to direct execution
                    logger.log("[intent] Opus failed, falling back to direct")
                    guard let (ss, _, _, _, _) = screenshotBase64() else { return }
                    overlay.setState(.thinking)
                    let summary = await fastPathExecute(
                        userInput: capturedInput,
                        screenshotData: ss,
                        orchestrator: orchestrator,
                        client: client,
                        executor: executor,
                        logger: logger,
                        sonnetPrompt: sonnetPrompt,
                        sonnetDirectPrompt: sonnetDirectPrompt,
                        maxIterationsPerBlock: maxIterationsPerBlock,
                        maxReplans: maxReplans,
                        maxDirectIterations: maxDirectIterations,
                        overlay: overlay,
                        voice: voice,
                        narrationQueue: narrationQueue,
                        clarificationBridge: clarificationBridge,
                        sessionContext: capturedContext
                    )
                    sessionContext.addAgentTurn(summary)
                    if !Task.isCancelled {
                        overlay.setState(.speaking)
                        narrationQueue.enqueue(summary)
                    }
                    return
                }

                // Store memory if any
                if let remember = intent.remember, !remember.isEmpty {
                    memoryStore.add(remember)
                }

                // Immediate spoken response (acknowledgment)
                if let response = intent.response, !response.isEmpty {
                    narrationQueue.enqueue(response)
                }

                switch intent.type {
                case "command", "followup":
                    // Execute the refined directive
                    guard let (ss, _, _, _, _) = screenshotBase64() else { return }
                    overlay.setState(.acting)
                    let summary = await fastPathExecute(
                        userInput: intent.directive,
                        screenshotData: ss,
                        orchestrator: orchestrator,
                        client: client,
                        executor: executor,
                        logger: logger,
                        sonnetPrompt: sonnetPrompt,
                        sonnetDirectPrompt: sonnetDirectPrompt,
                        maxIterationsPerBlock: maxIterationsPerBlock,
                        maxReplans: maxReplans,
                        maxDirectIterations: maxDirectIterations,
                        overlay: overlay,
                        voice: voice,
                        narrationQueue: narrationQueue,
                        clarificationBridge: clarificationBridge,
                        sessionContext: capturedContext
                    )

                    let totalDuration = ContinuousClock.now - requestStart
                    print("[Done] (\(totalDuration)) \(summary)")
                    logger.log("[done] \(totalDuration) | \(summary)")
                    sessionContext.addAgentTurn(summary)

                    if !Task.isCancelled {
                        overlay.setState(.speaking)
                        narrationQueue.enqueue(summary)
                    }

                case "interrupt":
                    // Already cancelled above — just acknowledge
                    logger.log("[intent] interrupt acknowledged")

                case "chat":
                    // Conversational — response already spoken above
                    let resp = intent.response ?? "I'm here to help."
                    sessionContext.addAgentTurn(resp)
                    let totalDuration = ContinuousClock.now - requestStart
                    print("[Chat] (\(totalDuration)) \(resp)")
                    logger.log("[chat] \(totalDuration) | \(resp)")
                    perfGuard.emitNoAction(reason: "chat")
                    overlay.setState(.idle)

                case "memory":
                    // Memory stored above, response spoken above
                    let resp = intent.response ?? "Got it, I'll remember that."
                    sessionContext.addAgentTurn(resp)
                    logger.log("[memory] stored, acknowledged")
                    perfGuard.emitNoAction(reason: "memory")
                    overlay.setState(.idle)

                default:
                    // Unknown type — treat as command
                    guard let (ss, _, _, _, _) = screenshotBase64() else { return }
                    overlay.setState(.acting)
                    let summary = await fastPathExecute(
                        userInput: intent.directive,
                        screenshotData: ss,
                        orchestrator: orchestrator,
                        client: client,
                        executor: executor,
                        logger: logger,
                        sonnetPrompt: sonnetPrompt,
                        sonnetDirectPrompt: sonnetDirectPrompt,
                        maxIterationsPerBlock: maxIterationsPerBlock,
                        maxReplans: maxReplans,
                        maxDirectIterations: maxDirectIterations,
                        overlay: overlay,
                        voice: voice,
                        narrationQueue: narrationQueue,
                        clarificationBridge: clarificationBridge,
                        sessionContext: capturedContext
                    )
                    sessionContext.addAgentTurn(summary)
                    if !Task.isCancelled {
                        narrationQueue.enqueue(summary)
                    }
                }
            }
        }

        // Wait for action to complete, but LISTEN for voice interruptions.
        // This lets the user say "stop" or correct the system mid-execution.
        //
        // Flow: wait for narration → open mic → if user speaks, cancel action and
        // feed their speech back as a new command. If silence, check if done, repeat.
        //
        // Also handles clarification: if the action task is waiting for an answer
        // via ClarificationBridge, we listen specifically for that.
        if let completion = actionCompletion {
            interruptWait: while !completion.isDone {
                if clarificationBridge.isPending {
                    // The action task is blocked waiting for a clarification answer.
                    // Wait for TTS to finish speaking the question, then listen.
                    while narrationQueue.isActive {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    overlay.setState(.listening, detail: "Clarifying")
                    if let answer = await voice.listen(onStablePartial: { _ in }) {
                        narrationQueue.unmute()
                        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            logger.log("[clarification answer] \(trimmed)")
                            print("[Clarification] \"\(trimmed)\"")
                            clarificationBridge.provideAnswer(trimmed)
                        }
                    } else {
                        narrationQueue.unmute()
                    }
                } else {
                    // Mic stays OFF during action — narration plays freely.
                    // listen() mutes TTS (echo prevention) which kills all narration,
                    // so we simply poll here and let the user hear what the agent is doing.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            // Clean up if action completed normally
            actionTask = nil
            actionCompletion = nil
        }

        // Let completion narration play before the mic opens.
        // interruptAndEnqueue has a 50ms debounce, so wait for it to start,
        // then let it play for up to 5 seconds. listen() at top of loop will
        // mute/cut off anything still playing when the user starts speaking.
        if narrationQueue.isActive || true {
            // Wait for debounced enqueue to fire
            try? await Task.sleep(nanoseconds: 150_000_000)
            // Now let narration play (max 5s so user isn't stuck)
            let waitStart = ContinuousClock.now
            while narrationQueue.isActive {
                if ContinuousClock.now - waitStart > .seconds(5) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

// MARK: - Text Mode

func runTextMode(
    orchestrator: Orchestrator,
    client: AnthropicClient,
    executor: ActionExecutor,
    logger: SessionLogger,
    sonnetPrompt: String,
    sonnetDirectPrompt: String,
    maxIterationsPerBlock: Int,
    maxReplans: Int,
    maxDirectIterations: Int,
    overlay: OverlayManager
) async {
    print("CUA - Computer Use Agent")
    print("Commands: 'quit', 'voice', or type a request")
    print("")

    while true {
        print("> ", terminator: "")
        fflush(stdout)

        guard let userInput = readLine(), !userInput.isEmpty else { break }
        if userInput == "quit" { break }

        if userInput == "voice" {
            await runVoiceMode(
                orchestrator: orchestrator,
                client: client,
                executor: executor,
                logger: logger,
                sonnetPrompt: sonnetPrompt,
                sonnetDirectPrompt: sonnetDirectPrompt,
                maxIterationsPerBlock: maxIterationsPerBlock,
                maxReplans: maxReplans,
                maxDirectIterations: maxDirectIterations,
                overlay: overlay
            )
            return
        }

        let requestStart = ContinuousClock.now
        logger.logSeparator()
        logger.log("USER: \(userInput)")

        guard let (screenshotData, _, _, _, _) = screenshotBase64() else {
            print("Warning: Failed to capture screen.")
            continue
        }

        let summary = await fastPathExecute(
            userInput: userInput,
            screenshotData: screenshotData,
            orchestrator: orchestrator,
            client: client,
            executor: executor,
            logger: logger,
            sonnetPrompt: sonnetPrompt,
            sonnetDirectPrompt: sonnetDirectPrompt,
            maxIterationsPerBlock: maxIterationsPerBlock,
            maxReplans: maxReplans,
            maxDirectIterations: maxDirectIterations,
            overlay: overlay
        )

        overlay.setState(.idle)
        let totalDuration = ContinuousClock.now - requestStart
        print("[Done] (\(totalDuration)) \(summary)")
        print("")
    }
}

// MARK: - Entry point

loadEnvFile()

// NSApplication provides a proper main run loop on Thread 0,
// ensuring DispatchQueue.main and @MainActor code runs on the actual main thread.
// This is required for AppKit (NSWindow overlay).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no dock icon, no menu bar

Task {
    await run()
}

app.run()  // takes over the main thread (never returns)
