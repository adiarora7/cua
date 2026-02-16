import Foundation

/// Opus-powered manager that plans work pipelines, monitors execution,
/// and re-plans when blocks fail.
final class Orchestrator: @unchecked Sendable {
    private let client: AnthropicClient
    private let logger: SessionLogger?

    init(client: AnthropicClient, logger: SessionLogger?) {
        self.client = client
        self.logger = logger
    }

    // MARK: - Pipeline planning

    private let pipelinePrompt = """
    You are an intelligent manager planning computer-use tasks on macOS.

    Given the user's request and a screenshot of the current screen, break the task into sequential work blocks.

    Each block should be:
    - A self-contained goal that can be verified visually
    - Achievable in under 10 action steps
    - Concrete and actionable (include keyboard shortcuts, exact URLs, click targets)

    macOS tips to include in directives:
    - Open apps: Click Dock icon if visible, otherwise Spotlight (cmd+space, type name, Return)
    - Browser URL bar: cmd+L, type URL, Return
    - Find on page: cmd+F, type term
    - Tab between form fields: Tab key
    - PREFER URL parameters over clicking form fields on search sites. Examples:
      • Google Flights: google.com/travel/flights?q=Amsterdam+to+Lisbon+on+2025-02-15
      • Google Search: google.com/search?q=your+query
      • Amazon: amazon.com/s?k=search+terms
      This is MUCH more reliable than clicking custom form elements.

    IMPORTANT — Clarifying questions:
    If the user's request is ambiguous or missing key details needed to complete the task:
    1. Include a "clarifications" array with SHORT, specific questions (one question per item)
    2. STILL plan blocks for the parts you CAN execute right now WITHOUT the user's answers
    3. STOP your block list BEFORE any block that would need the missing information. Those blocks will be planned later after the user answers.
    4. Each question should be concise (under 15 words) — they are asked via voice one at a time
    5. Ask at most 2 clarifying questions

    The clarifications will be asked via voice WHILE the initial blocks execute in parallel.
    Only ask questions that genuinely affect what actions to take. Don't ask about trivial details.

    Example: User says "find flights to Europe"
    → blocks: [open Chrome, navigate to Google Flights]
    → clarifications: ["Which city in Europe?", "One-way or round trip?"]
    WRONG: including a block like "fill in the search form with..." when you don't know the city yet

    Rules:
    - 1-4 blocks total. Simple tasks = 1 block. Complex multi-step tasks = 2-4 blocks.
    - Each block's directive should be 1-3 sentences, specific and actionable
    - expected_outcome should describe what the screen looks like when the block succeeds
    - Combine tightly-coupled actions (e.g. cmd+space, type, Return) into ONE block — don't split keyboard sequences across blocks
    - DON'T include "wait" or "verify" blocks

    Respond with ONLY a JSON object:
    {
      "blocks": [
        {
          "directive": "Open Google Chrome via Spotlight (cmd+space, type 'Google Chrome', Return)",
          "expected_outcome": "Google Chrome browser is open and visible"
        }
      ],
      "clarifications": ["Which city?"]
    }

    If no clarifications are needed, omit the "clarifications" field or set it to an empty array.

    CRITICAL: Respond with ONLY the JSON object. No explanation, no preamble, no commentary before or after the JSON.
    """

    struct WorkBlock: Sendable {
        let directive: String
        let expectedOutcome: String
    }

    struct PipelineResponse: Sendable {
        let blocks: [WorkBlock]
        let clarifications: [String]
    }

    /// Opus plans a pipeline of work blocks for the user's request.
    func planPipeline(userRequest: String, screenshotBase64: String) async throws -> PipelineResponse {
        let start = ContinuousClock.now

        let messages = [
            Message(role: "user", content: [
                .image(ImageSource.base64(data: screenshotBase64, mediaType: "image/jpeg")),
                .text(userRequest)
            ])
        ]

        let response = try await client.sendMessage(
            messages: messages,
            systemPrompt: pipelinePrompt,
            model: .opus
        )

        let duration = ContinuousClock.now - start
        logger?.log("[opus planPipeline] \(duration)")

        return try parsePipeline(from: response)
    }

    // MARK: - Quick block evaluation

    private let blockEvalPrompt = """
    You are quickly checking whether a computer-use agent completed a task step.

    Look at the screenshot and compare it to the expected outcome.

    Respond with ONLY a JSON object:
    {
      "status": "ok" or "failed",
      "summary": "One sentence describing what you see"
    }

    "ok" = the expected outcome was achieved (or close enough to proceed)
    "failed" = the expected outcome was NOT achieved, needs re-planning

    IMPORTANT: Only judge whether THIS SPECIFIC expected outcome was met. Do NOT consider the broader task.
    """

    enum BlockStatus: Sendable {
        case ok(summary: String)
        case failed(summary: String)
        case taskComplete(summary: String)
    }

    /// Quick evaluation: does the screen match the expected outcome of a block?
    func evaluateBlock(
        expectedOutcome: String,
        screenshotBase64: String,
        iterations: Int,
        hitLimit: Bool,
        blockNumber: Int,
        totalBlocks: Int
    ) async throws -> BlockStatus {
        let start = ContinuousClock.now

        var context = "Block \(blockNumber) of \(totalBlocks)\n"
        context += "Expected outcome for THIS block: \(expectedOutcome)\n"
        context += "Agent used \(iterations) iterations"
        if hitLimit {
            context += " (HIT ITERATION LIMIT — likely stuck or incomplete)"
        } else {
            context += " (stopped naturally — likely done)"
        }

        let messages = [
            Message(role: "user", content: [
                .image(ImageSource.base64(data: screenshotBase64, mediaType: "image/jpeg")),
                .text(context)
            ])
        ]

        let response = try await client.sendMessage(
            messages: messages,
            systemPrompt: blockEvalPrompt,
            model: .opus
        )

        let duration = ContinuousClock.now - start
        logger?.log("[opus evaluateBlock] \(duration)")

        return try parseBlockStatus(from: response)
    }

    // MARK: - Re-planning

    private let replanPrompt = """
    You are an intelligent manager re-planning after a computer-use agent got stuck.

    You will receive:
    1. The original user request
    2. What was accomplished so far
    3. A screenshot of the CURRENT screen state

    Create a NEW pipeline of work blocks to complete the remaining task.

    Rules:
    - Use DIFFERENT approaches from what failed — STRONGLY prefer keyboard shortcuts over clicking
    - If a dialog/compose window is minimized or collapsed, DON'T click it again. Instead: press Escape to dismiss, then use a keyboard shortcut to reopen
    - Gmail keyboard shortcuts: 'c' = new compose, 'r' = reply, '/' = search, Tab = next field
    - Browser shortcuts: cmd+L = address bar, cmd+T = new tab, cmd+W = close tab
    - Use Tab to navigate between form fields instead of clicking
    - PREFER URL parameters over clicking form fields on search sites. If an agent couldn't interact with form fields, navigate via URL instead:
      • Google Flights: cmd+L, type google.com/travel/flights?q=Amsterdam+to+Lisbon+on+2025-02-15, Return
      • Google Search: cmd+L, type google.com/search?q=your+query, Return
      • Amazon: cmd+L, type amazon.com/s?k=search+terms, Return
    - 1-3 blocks for the remaining work
    - Be specific and creative — your directive should include exact key sequences

    Respond with ONLY a JSON object:
    {
      "blocks": [
        {
          "directive": "...",
          "expected_outcome": "..."
        }
      ]
    }
    """

    /// Re-plan remaining work after a block fails.
    func replan(
        userRequest: String,
        accomplishedSoFar: String,
        screenshotBase64: String
    ) async throws -> [WorkBlock] {
        let start = ContinuousClock.now

        let context = """
        Original request: \(userRequest)
        Accomplished so far: \(accomplishedSoFar)
        The previous approach got stuck. Plan a NEW approach using DIFFERENT methods.
        """

        let messages = [
            Message(role: "user", content: [
                .image(ImageSource.base64(data: screenshotBase64, mediaType: "image/jpeg")),
                .text(context)
            ])
        ]

        let response = try await client.sendMessage(
            messages: messages,
            systemPrompt: replanPrompt,
            model: .opus
        )

        let duration = ContinuousClock.now - start
        logger?.log("[opus replan] \(duration)")

        return try parsePipeline(from: response).blocks
    }

    /// Re-plan with user's clarification answers.
    func replanWithClarification(
        originalRequest: String,
        clarificationAnswers: String,
        accomplishedSoFar: String,
        screenshotBase64: String
    ) async throws -> [WorkBlock] {
        let start = ContinuousClock.now

        let context = """
        Original request: \(originalRequest)
        Accomplished so far: \(accomplishedSoFar)
        The user provided these clarifications: \(clarificationAnswers)
        Plan the remaining work to complete the task with these details.
        """

        let messages = [
            Message(role: "user", content: [
                .image(ImageSource.base64(data: screenshotBase64, mediaType: "image/jpeg")),
                .text(context)
            ])
        ]

        let response = try await client.sendMessage(
            messages: messages,
            systemPrompt: replanPrompt,
            model: .opus
        )

        let duration = ContinuousClock.now - start
        logger?.log("[opus replanWithClarification] \(duration)")

        return try parsePipeline(from: response).blocks
    }

    // MARK: - Legacy single-directive (kept for fallback)

    struct Directive: Sendable {
        let text: String
        let isComplex: Bool
    }

    enum TaskStatus: Sendable {
        case done(summary: String)
        case needsRetry(summary: String, newDirective: String)
    }

    // MARK: - Parsing

    private func parsePipeline(from response: APIResponse) throws -> PipelineResponse {
        let jsonText = try extractJSON(from: response)
        logger?.log("[opus pipeline] \(jsonText)")

        guard let data = jsonText.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocksArray = parsed["blocks"] as? [[String: Any]] else {
            throw OrchestratorError.parseError("Could not parse pipeline blocks")
        }

        var blocks: [WorkBlock] = []
        for blockDict in blocksArray {
            guard let directive = blockDict["directive"] as? String,
                  let expectedOutcome = blockDict["expected_outcome"] as? String else {
                continue
            }
            blocks.append(WorkBlock(directive: directive, expectedOutcome: expectedOutcome))
        }

        let clarifications = (parsed["clarifications"] as? [String]) ?? []

        // Valid: blocks only, blocks + clarifications, or clarifications only
        if blocks.isEmpty && clarifications.isEmpty {
            throw OrchestratorError.parseError("Pipeline has no valid blocks or clarifications")
        }

        return PipelineResponse(blocks: blocks, clarifications: clarifications)
    }

    private func parseBlockStatus(from response: APIResponse) throws -> BlockStatus {
        let jsonText = try extractJSON(from: response)
        logger?.log("[opus blockEval] \(jsonText)")

        guard let data = jsonText.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = parsed["status"] as? String,
              let summary = parsed["summary"] as? String else {
            throw OrchestratorError.parseError("Could not parse block evaluation")
        }

        switch status {
        case "ok", "complete":
            return .ok(summary: summary)
        default:
            return .failed(summary: summary)
        }
    }

    private func extractJSON(from response: APIResponse) throws -> String {
        var fullText = ""
        for block in response.content {
            if case .text(let text) = block {
                fullText += text
            }
        }

        var jsonText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code blocks
        if jsonText.hasPrefix("```json") {
            jsonText = String(jsonText.dropFirst(7))
        } else if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
        }
        if jsonText.hasSuffix("```") {
            jsonText = String(jsonText.dropLast(3))
        }
        jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle prose before/after JSON — find the JSON object
        if !jsonText.hasPrefix("{") && !jsonText.hasPrefix("[") {
            if let start = jsonText.firstIndex(of: "{"),
               let end = jsonText.lastIndex(of: "}") {
                jsonText = String(jsonText[start...end])
            }
        }

        return jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OrchestratorError: Error, CustomStringConvertible {
    case parseError(String)

    var description: String {
        switch self {
        case .parseError(let detail):
            return "Orchestrator error: \(detail)"
        }
    }
}
