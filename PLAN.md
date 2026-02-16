# CUA — Voice-First Computer Use Agent: Implementation Plan

## Phase 1: Core Loop Validation (Tonight)

**Goal:** Prove the loop works end-to-end: capture screen → Opus reasons → execute action → confirm.

### Project Structure

```
cua/
├── Package.swift
├── Sources/
│   └── CUA/
│       ├── main.swift              # Entry point + REPL + agent loop
│       ├── ScreenCapture.swift     # Screen capture via CGWindowListCreateImage
│       ├── AnthropicClient.swift   # Anthropic Messages API client (computer use)
│       ├── ActionExecutor.swift    # Mouse/keyboard via CGEvent
│       └── Models.swift            # Codable types for API request/response
```

### File-by-File Implementation

#### 1. `Package.swift`
- macOS 14.0+ deployment target
- Single executable product `CUA`
- No external dependencies — only Apple frameworks (Foundation, CoreGraphics, ApplicationServices)

#### 2. `Models.swift` — API Types
Codable structs mirroring the Anthropic Messages API:
- `APIRequest` — model, max_tokens, system, tools, messages
- `APIResponse` — id, content (array of content blocks), stop_reason
- `ContentBlock` — enum: text(String) | tool_use(id, name, input) | image(source)
- `ToolInput` — the computer action: action name + coordinate/text/key params
- `ComputerAction` — parsed enum: leftClick(x,y), rightClick(x,y), doubleClick(x,y), type(String), key(String), scroll(x,y,direction,amount), mouseMove(x,y), screenshot
- `Message` — role (user/assistant) + content blocks
- `ToolDefinition` — type: "computer_20241022", display dimensions

#### 3. `ScreenCapture.swift` — Screen Capture
Key function: `captureScreen() -> (pngData: Data, width: Int, height: Int)`
- Uses `CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)`
- Creates NSBitmapImageRep → PNG data
- Returns both image data and logical display dimensions
- For Retina: capture at native resolution, but report **logical** dimensions to the API so coordinates map directly to CGEvent point space
- Get logical dimensions via `CGDisplayPixelsWide/High(CGMainDisplayID())`

#### 4. `AnthropicClient.swift` — API Client
Key function: `sendMessage(messages:systemPrompt:) async throws -> APIResponse`

API details:
- Endpoint: `POST https://api.anthropic.com/v1/messages`
- Headers:
  - `x-api-key: <ANTHROPIC_API_KEY>`
  - `anthropic-version: 2023-06-01`
  - `anthropic-beta: computer-use-2024-10-22`
  - `content-type: application/json`
- Tool definition:
  ```json
  {
    "type": "computer_20241022",
    "name": "computer",
    "display_width_px": <logical_width>,
    "display_height_px": <logical_height>,
    "display_number": 1
  }
  ```
- Model: `claude-opus-4-6-20250219`
- Max tokens: 4096

Configuration:
- Reads `ANTHROPIC_API_KEY` from environment
- Accepts display dimensions at init
- Image content sent as: `{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}`

#### 5. `ActionExecutor.swift` — Mouse/Keyboard Control
Key function: `execute(_ action: ComputerAction) async throws`

Actions:
- **leftClick/rightClick/doubleClick(x, y):** CGEvent mouse down + up at coordinates. Coordinate values from API are in logical points (matches CGEvent space directly since we report logical dims to API).
- **type(text):** For each character, use CGEvent keyDown/keyUp. Or use the CGEvent keyboard approach with `CGEvent(keyboardEventSource:virtualKey:keyDown:)`. Simpler: use the clipboard — copy text to pasteboard, then simulate Cmd+V.
- **key(keys):** Parse key names (Return, Tab, space, etc.) to virtual key codes, send CGEvent.
- **scroll(x, y, direction, amount):** CGEvent scroll wheel event.
- **mouseMove(x, y):** CGEvent mouse moved.
- **screenshot:** No-op — the loop handles this.

Add small delays (100-200ms) after each action to let the UI update before next screenshot.

#### 6. `main.swift` — Entry Point + Agent Loop

```
1. Read ANTHROPIC_API_KEY from env (exit with error if missing)
2. Get display dimensions
3. Print welcome message
4. REPL loop:
   a. Print "> " prompt, read user input from stdin
   b. Capture screenshot
   c. Build initial message: [image(screenshot), text(user_input)]
   d. Agent loop:
      i.   Send messages to Opus
      ii.  If response has tool_use block:
           - Parse action from tool input
           - Print narration: "Clicking at (x, y)..." / "Typing '...'"
           - Execute action
           - Wait 500ms for screen to update
           - Capture new screenshot
           - Append assistant response + tool_result (with new screenshot) to messages
           - Continue loop
      iii. If response has text only (or stop_reason != "tool_use"):
           - Print the text response
           - Break inner loop
   e. Keep conversation history for context (reset on "reset" command)
```

### Retina Coordinate Strategy
- **Capture:** Full native resolution screenshot (for visual quality)
- **Report to API:** Logical display dimensions (e.g., 1512x982 on 14" M2 MacBook)
- **Receive from API:** Coordinates in logical point space
- **Execute with CGEvent:** Use coordinates directly (CGEvent uses logical points)
- This means: no coordinate conversion needed. The API thinks the screen is 1512x982, returns coords in that space, CGEvent operates in that space.

However, the screenshot image itself is 2x resolution. We should **downscale the image to logical resolution before sending** to match the coordinate space we report. This ensures what Opus "sees" matches the coordinate grid.

### macOS Permissions Required
1. **Screen Recording** — needed for CGWindowListCreateImage. System will prompt on first use. Grant to Terminal.app (or whatever runs the binary).
2. **Accessibility** — needed for CGEvent to control mouse/keyboard. Must be granted in System Settings → Privacy & Security → Accessibility. Grant to Terminal.app.

### Build & Run
```bash
cd /Users/adiarora/dev/cua
swift build
ANTHROPIC_API_KEY=sk-ant-... .build/debug/CUA
```

### Validation Test
1. Run CUA
2. Type: "Click on the Safari icon in the dock"
3. Expect: agent captures screen, Opus identifies Safari icon, returns left_click, CUA clicks it, Safari opens
4. Agent takes new screenshot, Opus says "Safari is now open" or similar

---

## Phase 2: SwiftUI App + Overlay (Day 2-3)
- Convert to proper macOS app bundle with SwiftUI
- Floating translucent window (always on top, no title bar)
- Text input field at bottom, conversation scrollview above
- Green circle overlay at click coordinates (fades after 1s)
- Proper app icon, menu bar presence
- Entitlements file for screen recording + accessibility

## Phase 3: Voice Integration (Day 3-4)
- whisper.cpp integrated via Swift C interop for speech-to-text
- Kokoro-82M for TTS (local Python sidecar server, Swift calls via HTTP)
- Push-to-talk (hold spacebar when app focused) or hotkey trigger
- Filler phrases ("Let me look at that...") play immediately while Opus thinks
- Stream TTS: start speaking first sentence while rest generates

## Phase 4: Memory System (Day 4-5)
- JSON file at `~/.cua/memory.json`
- Add `remember` tool to Opus's tool list — Opus calls it when it identifies something worth storing
- Schema: `[{context: string, fact: string, timestamp: string}]`
- Inject relevant memories into system prompt each session
- Demo: book a flight, agent remembers seat preference for next time

## Phase 5: Polish & Demo (Day 5-6)
- Record demo video (3 min)
- Test with non-technical family member
- Error recovery UX (agent says "that didn't work, let me try again")
- README, license, open source prep
