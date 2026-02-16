import Foundation

// MARK: - Prompt Caching

struct CacheControl: Codable, Sendable {
    let type: String
    static let ephemeral = CacheControl(type: "ephemeral")
}

struct SystemBlock: Codable, Sendable {
    let type: String  // "text"
    let text: String
    let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    static func text(_ content: String, cache: Bool = false) -> SystemBlock {
        SystemBlock(type: "text", text: content, cacheControl: cache ? .ephemeral : nil)
    }
}

// MARK: - Request Types

struct APIRequest: Sendable {
    let model: String
    let maxTokens: Int
    let system: String?
    let systemBlocks: [SystemBlock]?
    let tools: [ToolDefinition]?
    let messages: [Message]

    init(model: String, maxTokens: Int, system: String? = nil, systemBlocks: [SystemBlock]? = nil, tools: [ToolDefinition]? = nil, messages: [Message]) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.systemBlocks = systemBlocks
        self.tools = tools
        self.messages = messages
    }
}

extension APIRequest: Codable {
    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case tools
        case messages
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        // If systemBlocks is set, encode system key as array; otherwise as string
        if let blocks = systemBlocks {
            try container.encode(blocks, forKey: .system)
        } else if let s = system {
            try container.encode(s, forKey: .system)
        }
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encode(messages, forKey: .messages)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        self.maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        self.system = try container.decodeIfPresent(String.self, forKey: .system)
        self.systemBlocks = nil
        self.tools = try container.decodeIfPresent([ToolDefinition].self, forKey: .tools)
        self.messages = try container.decode([Message].self, forKey: .messages)
    }
}

struct Message: Codable, Sendable {
    let role: String
    let content: [ContentBlock]
}

// Standard tool definition with JSON Schema input
struct ToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }

    static func computer(displayWidth: Int, displayHeight: Int) -> ToolDefinition {
        ToolDefinition(
            name: "computer",
            description: """
                Control the computer's mouse and keyboard. The screen is \(displayWidth)x\(displayHeight) pixels. \
                Coordinates (0,0) are at the top-left corner. \
                You always receive a fresh screenshot after your actions execute — never request one manually.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("left_click"), .string("right_click"), .string("double_click"),
                            .string("middle_click"), .string("type"), .string("key"),
                            .string("scroll"), .string("mouse_move"), .string("left_click_drag")
                        ]),
                        "description": .string("The action to perform")
                    ]),
                    "coordinate": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("[x, y] pixel coordinates for click/scroll/move actions, or end coordinate for drag")
                    ]),
                    "start_coordinate": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("[x, y] start pixel coordinates for left_click_drag action")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to type (for 'type' action)")
                    ]),
                    "key": .object([
                        "type": .string("string"),
                        "description": .string("Key(s) to press (for 'key' action), e.g. 'Return', 'cmd+a', 'space'")
                    ]),
                    "scroll_direction": .object([
                        "type": .string("string"),
                        "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")]),
                        "description": .string("Scroll direction (for 'scroll' action)")
                    ]),
                    "scroll_amount": .object([
                        "type": .string("integer"),
                        "description": .string("Number of scroll ticks, default 3 (for 'scroll' action)")
                    ])
                ]),
                "required": .array([.string("action")])
            ])
        )
    }
}

// Generic JSON value for encoding arbitrary JSON (used for input_schema)
indirect enum JSONValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Content Blocks

enum ContentBlock: Codable, Sendable {
    case text(String)
    case image(ImageSource)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let textContainer = try decoder.singleValueContainer()
            let textBlock = try textContainer.decode(TextBlock.self)
            self = .text(textBlock.text)

        case "image":
            let imageContainer = try decoder.singleValueContainer()
            let imageBlock = try imageContainer.decode(ImageBlock.self)
            self = .image(imageBlock.source)

        case "tool_use":
            let toolUseContainer = try decoder.singleValueContainer()
            let toolUseBlock = try toolUseContainer.decode(ToolUseBlock.self)
            self = .toolUse(toolUseBlock)

        case "tool_result":
            let toolResultContainer = try decoder.singleValueContainer()
            let toolResultBlock = try toolResultContainer.decode(ToolResultBlock.self)
            self = .toolResult(toolResultBlock)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.singleValueContainer()
            try container.encode(TextBlock(text: text))

        case .image(let source):
            var container = encoder.singleValueContainer()
            try container.encode(ImageBlock(source: source))

        case .toolUse(let block):
            var container = encoder.singleValueContainer()
            try container.encode(block)

        case .toolResult(let block):
            var container = encoder.singleValueContainer()
            try container.encode(block)
        }
    }

    // Helper structs for encoding/decoding
    private struct TextBlock: Codable {
        let type = "text"
        let text: String
    }

    private struct ImageBlock: Codable {
        let type = "image"
        let source: ImageSource
    }
}

struct ImageSource: Codable, Sendable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }

    static func base64(data: String, mediaType: String = "image/png") -> ImageSource {
        ImageSource(type: "base64", mediaType: mediaType, data: data)
    }
}

struct ToolUseBlock: Sendable {
    let id: String
    let type: String
    let name: String
    let input: ToolInput

    init(id: String, name: String, input: ToolInput) {
        self.id = id
        self.type = "tool_use"
        self.name = name
        self.input = input
    }
}

extension ToolUseBlock: Codable {
    enum CodingKeys: String, CodingKey {
        case id, type, name, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decode(String.self, forKey: .type)
        self.name = try container.decode(String.self, forKey: .name)
        // Decode input as raw JSON dict then map to ToolInput
        let rawInput = try container.decode([String: JSONValue].self, forKey: .input)
        self.input = ToolInput.from(rawInput)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(input, forKey: .input)
    }
}

struct ToolResultBlock: Codable, Sendable {
    let type: String
    let toolUseId: String
    let content: [ContentBlock]

    init(toolUseId: String, content: [ContentBlock]) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.toolUseId = try container.decode(String.self, forKey: .toolUseId)
        self.content = try container.decode([ContentBlock].self, forKey: .content)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(toolUseId, forKey: .toolUseId)
        try container.encode(content, forKey: .content)
    }
}

struct ToolInput: Codable, Sendable {
    let action: String
    let coordinate: [Int]?
    let startCoordinate: [Int]?
    let text: String?
    let key: String?
    let scrollDirection: String?
    let scrollAmount: Int?

    enum CodingKeys: String, CodingKey {
        case action
        case coordinate
        case startCoordinate = "start_coordinate"
        case text
        case key
        case scrollDirection = "scroll_direction"
        case scrollAmount = "scroll_amount"
    }

    init(
        action: String,
        coordinate: [Int]? = nil,
        startCoordinate: [Int]? = nil,
        text: String? = nil,
        key: String? = nil,
        scrollDirection: String? = nil,
        scrollAmount: Int? = nil
    ) {
        self.action = action
        self.coordinate = coordinate
        self.startCoordinate = startCoordinate
        self.text = text
        self.key = key
        self.scrollDirection = scrollDirection
        self.scrollAmount = scrollAmount
    }

    /// Parse from raw JSON dictionary (from API tool_use response)
    static func from(_ raw: [String: JSONValue]) -> ToolInput {
        let action: String = {
            if case .string(let s) = raw["action"] { return s }
            return "unknown"
        }()
        let coordinate: [Int]? = {
            if case .array(let arr) = raw["coordinate"] {
                return arr.compactMap { if case .int(let i) = $0 { return i } else { return nil } }
            }
            return nil
        }()
        let startCoordinate: [Int]? = {
            if case .array(let arr) = raw["start_coordinate"] {
                return arr.compactMap { if case .int(let i) = $0 { return i } else { return nil } }
            }
            return nil
        }()
        let text: String? = {
            if case .string(let s) = raw["text"] { return s }
            return nil
        }()
        let key: String? = {
            if case .string(let s) = raw["key"] { return s }
            return nil
        }()
        let scrollDirection: String? = {
            if case .string(let s) = raw["scroll_direction"] { return s }
            return nil
        }()
        let scrollAmount: Int? = {
            if case .int(let i) = raw["scroll_amount"] { return i }
            return nil
        }()
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
}

// MARK: - Response Types

struct APIResponse: Codable, Sendable {
    let id: String
    let type: String
    let role: String
    let content: [ContentBlock]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case content
        case stopReason = "stop_reason"
    }
}

// MARK: - Parsed Action Type

enum ComputerAction: Sendable {
    case leftClick(x: Int, y: Int)
    case rightClick(x: Int, y: Int)
    case doubleClick(x: Int, y: Int)
    case middleClick(x: Int, y: Int)
    case type(text: String)
    case key(keys: String)
    case scroll(x: Int, y: Int, direction: String, amount: Int)
    case mouseMove(x: Int, y: Int)
    case leftClickDrag(startX: Int, startY: Int, endX: Int, endY: Int)
    case screenshot
    case cursorPosition

    init?(from input: ToolInput) {
        switch input.action {
        case "left_click":
            guard let coordinate = input.coordinate, coordinate.count == 2 else {
                return nil
            }
            self = .leftClick(x: coordinate[0], y: coordinate[1])

        case "right_click":
            guard let coordinate = input.coordinate, coordinate.count == 2 else {
                return nil
            }
            self = .rightClick(x: coordinate[0], y: coordinate[1])

        case "double_click":
            guard let coordinate = input.coordinate, coordinate.count == 2 else {
                return nil
            }
            self = .doubleClick(x: coordinate[0], y: coordinate[1])

        case "middle_click":
            guard let coordinate = input.coordinate, coordinate.count == 2 else {
                return nil
            }
            self = .middleClick(x: coordinate[0], y: coordinate[1])

        case "type":
            guard let text = input.text else {
                return nil
            }
            self = .type(text: text)

        case "key":
            guard let keys = input.key else {
                return nil
            }
            self = .key(keys: keys)

        case "scroll":
            guard let coordinate = input.coordinate,
                  coordinate.count == 2,
                  let direction = input.scrollDirection else {
                return nil
            }
            let amount = input.scrollAmount ?? 3
            self = .scroll(x: coordinate[0], y: coordinate[1], direction: direction, amount: amount)

        case "mouse_move":
            guard let coordinate = input.coordinate, coordinate.count == 2 else {
                return nil
            }
            self = .mouseMove(x: coordinate[0], y: coordinate[1])

        case "left_click_drag":
            guard let startCoord = input.startCoordinate, startCoord.count == 2,
                  let endCoord = input.coordinate, endCoord.count == 2 else {
                return nil
            }
            self = .leftClickDrag(startX: startCoord[0], startY: startCoord[1], endX: endCoord[0], endY: endCoord[1])

        case "screenshot":
            self = .screenshot

        case "cursor_position":
            self = .cursorPosition

        default:
            return nil
        }
    }

    func toToolInput() -> ToolInput {
        switch self {
        case .leftClick(let x, let y):
            return ToolInput(action: "left_click", coordinate: [x, y])

        case .rightClick(let x, let y):
            return ToolInput(action: "right_click", coordinate: [x, y])

        case .doubleClick(let x, let y):
            return ToolInput(action: "double_click", coordinate: [x, y])

        case .middleClick(let x, let y):
            return ToolInput(action: "middle_click", coordinate: [x, y])

        case .type(let text):
            return ToolInput(action: "type", text: text)

        case .key(let keys):
            return ToolInput(action: "key", key: keys)

        case .scroll(let x, let y, let direction, let amount):
            return ToolInput(
                action: "scroll",
                coordinate: [x, y],
                scrollDirection: direction,
                scrollAmount: amount
            )

        case .mouseMove(let x, let y):
            return ToolInput(action: "mouse_move", coordinate: [x, y])

        case .leftClickDrag(let sx, let sy, let ex, let ey):
            return ToolInput(action: "left_click_drag", coordinate: [ex, ey], startCoordinate: [sx, sy])

        case .screenshot:
            return ToolInput(action: "screenshot")

        case .cursorPosition:
            return ToolInput(action: "cursor_position")
        }
    }
}
