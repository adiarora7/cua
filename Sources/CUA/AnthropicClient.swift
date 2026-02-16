import Foundation

enum APIError: Error, CustomStringConvertible {
    case httpError(statusCode: Int, body: String)
    case networkError(Error)

    var description: String {
        switch self {
        case .httpError(let statusCode, let body):
            return "HTTP Error \(statusCode): \(body)"
        case .networkError(let error):
            return "Network Error: \(error.localizedDescription)"
        }
    }
}

enum ModelChoice: String, Sendable {
    case haiku = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-4-5-20250929"
    case opus = "claude-opus-4-6"
}

final class AnthropicClient: @unchecked Sendable {
    private let apiKey: String
    private let displayWidth: Int
    private let displayHeight: Int
    private let endpoint = "https://api.anthropic.com/v1/messages"
    var logger: SessionLogger?

    init(apiKey: String, displayWidth: Int, displayHeight: Int) {
        self.apiKey = apiKey
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    /// Wrap a system prompt string in a cacheable SystemBlock array.
    private func makeSystemBlocks(_ prompt: String) -> [SystemBlock] {
        [SystemBlock.text(prompt, cache: true)]
    }

    func sendMessage(messages: [Message], systemPrompt: String, model: ModelChoice = .sonnet) async throws -> APIResponse {
        let modelId = model.rawValue

        // Only include computer tool for Sonnet (action model), not for Opus (planner)
        let tools: [ToolDefinition]?
        if model == .opus {
            tools = nil  // Opus is a planner — no tools
        } else {
            tools = [ToolDefinition.computer(displayWidth: displayWidth, displayHeight: displayHeight)]
        }

        // Build API request with prompt caching
        let request = APIRequest(
            model: modelId,
            maxTokens: 4096,
            systemBlocks: makeSystemBlocks(systemPrompt),
            tools: tools,
            messages: messages
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        let jsonData: Data
        do {
            jsonData = try encoder.encode(request)
        } catch {
            throw APIError.networkError(error)
        }

        // Create URL request
        guard let url = URL(string: endpoint) else {
            throw APIError.networkError(NSError(domain: "Invalid URL", code: -1))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = jsonData

        // Log request summary (skip full body — it contains large base64 images)
        if let logger = logger {
            let msgCount = messages.count
            let imgCount = messages.flatMap(\.content).filter { if case .image = $0 { return true } else { return false } }.count
            let toolResultImgCount = messages.flatMap(\.content).compactMap { block -> Int? in
                if case .toolResult(let tr) = block {
                    return tr.content.filter { if case .image = $0 { return true } else { return false } }.count
                }
                return nil
            }.reduce(0, +)
            logger.log("API REQUEST: \(msgCount) messages, \(imgCount + toolResultImgCount) screenshots, \(jsonData.count) bytes")
        }

        // Send request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw APIError.networkError(error)
        }

        // Check HTTP status code
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(NSError(domain: "Invalid response type", code: -1))
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unable to decode error body"
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // Log response (cap at 2KB to avoid bloat)
        if let logger = logger, let rawResponseStr = String(data: data, encoding: .utf8) {
            let capped = rawResponseStr.count > 2000 ? String(rawResponseStr.prefix(2000)) + "\n... [truncated]" : rawResponseStr
            logger.logRaw("API RESPONSE (\(data.count) bytes)", capped)
        }

        let decoder = JSONDecoder()

        do {
            let apiResponse = try decoder.decode(APIResponse.self, from: data)
            return apiResponse
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                print("Failed to decode response. Raw body:")
                print(raw)
            }
            throw APIError.networkError(error)
        }
    }

    // MARK: - Streaming

    /// Stream events from the API. Text deltas arrive as they're generated,
    /// enabling early GUIDE: prefix detection and highlight display.
    func streamMessage(
        messages: [Message],
        systemPrompt: String,
        model: ModelChoice = .haiku,
        onTextDelta: @escaping (String) -> Void
    ) async throws -> APIResponse {
        let modelId = model.rawValue

        let tools: [ToolDefinition]?
        if model == .opus {
            tools = nil
        } else {
            tools = [ToolDefinition.computer(displayWidth: displayWidth, displayHeight: displayHeight)]
        }

        // Build API request with stream: true and prompt caching
        let encoder = JSONEncoder()
        let baseRequest = APIRequest(
            model: modelId,
            maxTokens: 4096,
            systemBlocks: makeSystemBlocks(systemPrompt),
            tools: tools,
            messages: messages
        )
        var jsonData = try encoder.encode(baseRequest)

        // Inject "stream": true into the JSON
        if var jsonObj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            jsonObj["stream"] = true
            jsonData = try JSONSerialization.data(withJSONObject: jsonObj)
        }

        guard let url = URL(string: endpoint) else {
            throw APIError.networkError(NSError(domain: "Invalid URL", code: -1))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = jsonData

        if let logger = logger {
            let msgCount = messages.count
            let imgCount = messages.flatMap(\.content).filter { if case .image = $0 { return true } else { return false } }.count
            logger.log("API STREAM: \(msgCount) messages, \(imgCount) screenshots, \(jsonData.count) bytes")
        }

        // Use URLSession bytes for streaming
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(NSError(domain: "Invalid response", code: -1))
        }

        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // Parse SSE events
        var fullText = ""
        var toolUseBlocks: [ToolUseBlock] = []
        var currentToolId: String?
        var currentToolName: String?
        var currentToolJson = ""
        var stopReason: String?
        var messageId = ""

        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }

            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]" else { continue }
            guard let eventData = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let eventType = event["type"] as? String
            else { continue }

            switch eventType {
            case "message_start":
                if let msg = event["message"] as? [String: Any],
                   let id = msg["id"] as? String {
                    messageId = id
                }

            case "content_block_start":
                if let block = event["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String {
                    if blockType == "tool_use" {
                        currentToolId = block["id"] as? String
                        currentToolName = block["name"] as? String
                        currentToolJson = ""
                    }
                }

            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String {
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        fullText += text
                        onTextDelta(text)
                    } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                        currentToolJson += partial
                    }
                }

            case "content_block_stop":
                // Finalize tool_use block if we were building one
                if let toolId = currentToolId, let toolName = currentToolName {
                    if let jsonData = currentToolJson.data(using: .utf8),
                       let rawInput = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        // Convert to [String: JSONValue]
                        let toolInput = parseToolInputFromRaw(rawInput)
                        toolUseBlocks.append(ToolUseBlock(id: toolId, name: toolName, input: toolInput))
                    }
                    currentToolId = nil
                    currentToolName = nil
                    currentToolJson = ""
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }

            default:
                break
            }
        }

        // Build the equivalent APIResponse
        var contentBlocks: [ContentBlock] = []
        if !fullText.isEmpty {
            contentBlocks.append(.text(fullText))
        }
        for toolUse in toolUseBlocks {
            contentBlocks.append(.toolUse(toolUse))
        }

        logger?.log("STREAM COMPLETE: \(fullText.count) chars text, \(toolUseBlocks.count) tools, stop=\(stopReason ?? "nil")")

        return APIResponse(
            id: messageId,
            type: "message",
            role: "assistant",
            content: contentBlocks,
            stopReason: stopReason
        )
    }

    /// Parse raw JSON dictionary to ToolInput
    private func parseToolInputFromRaw(_ raw: [String: Any]) -> ToolInput {
        let action = raw["action"] as? String ?? "unknown"
        let coordinate: [Int]? = (raw["coordinate"] as? [Any])?.compactMap { $0 as? Int }
        let startCoordinate: [Int]? = (raw["start_coordinate"] as? [Any])?.compactMap { $0 as? Int }
        let text = raw["text"] as? String
        let key = raw["key"] as? String
        let scrollDirection = raw["scroll_direction"] as? String
        let scrollAmount = raw["scroll_amount"] as? Int
        return ToolInput(
            action: action,
            coordinate: coordinate,
            startCoordinate: startCoordinate,
            text: text,
            key: key,
            scrollDirection: scrollDirection,
            scrollAmount: scrollAmount
        )
    }

    func truncateImageData(_ base64: String, maxLength: Int = 1_000_000) -> String {
        if base64.count > maxLength {
            print("⚠️  Warning: Base64 image data is \(base64.count) characters, exceeds \(maxLength) limit")
            // For now, return as-is. Future: implement compression
        }
        return base64
    }
}
