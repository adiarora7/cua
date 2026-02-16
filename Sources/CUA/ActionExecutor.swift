import CoreGraphics
import Foundation
import AppKit

final class ActionExecutor: @unchecked Sendable {

    /// Maximize the frontmost window to fill the visible screen area (between menu bar and dock).
    /// Uses actual screen dimensions instead of hardcoded values.
    /// Fails silently if no window is available.
    func maximizeFrontWindow() {
        // Get actual visible area — excludes menu bar and dock
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let screenHeight = screen.frame.height

        // Convert NSScreen coordinates (origin bottom-left) to AppleScript (origin top-left)
        let appleY = Int(screenHeight - visible.origin.y - visible.height)
        let appleX = Int(visible.origin.x)
        let appleW = Int(visible.width)
        let appleH = Int(visible.height)

        let script = """
        tell application "System Events"
            set frontApp to first application process whose frontmost is true
            tell frontApp
                if (count of windows) > 0 then
                    set theWindow to window 1
                    set position of theWindow to {\(appleX), \(appleY)}
                    set size of theWindow to {\(appleW), \(appleH)}
                end if
            end tell
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            // Fallback: try setting to full screen via AX attribute
            let fallbackScript = """
            tell application "System Events"
                set frontApp to first application process whose frontmost is true
                tell frontApp
                    if (count of windows) > 0 then
                        set value of attribute "AXFullScreen" of window 1 to true
                    end if
                end tell
            end tell
            """
            let fallback = NSAppleScript(source: fallbackScript)
            fallback?.executeAndReturnError(nil)
            _ = err // suppress unused warning
        }
        // Brief sleep for window animation
        usleep(300_000) // 300ms
    }

    /// Scale factors for converting API coordinates to logical screen coordinates.
    /// Set after initial screenshot when API dimensions differ from logical dimensions.
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0

    /// Scale a coordinate from API space to logical screen space.
    private func scaled(x: Int, y: Int) -> (Int, Int) {
        (Int(Double(x) * scaleX), Int(Double(y) * scaleY))
    }

    func execute(_ action: ComputerAction) async {
        switch action {
        case .leftClick(let x, let y):
            let (sx, sy) = scaled(x: x, y: y)
            await performLeftClick(x: sx, y: sy)

        case .rightClick(let x, let y):
            let (sx, sy) = scaled(x: x, y: y)
            await performRightClick(x: sx, y: sy)

        case .doubleClick(let x, let y):
            let (sx, sy) = scaled(x: x, y: y)
            await performDoubleClick(x: sx, y: sy)

        case .middleClick(let x, let y):
            let (sx, sy) = scaled(x: x, y: y)
            await performMiddleClick(x: sx, y: sy)

        case .type(let text):
            await performType(text: text)

        case .key(let keys):
            await performKey(keys: keys)

        case .scroll(let x, let y, let direction, let amount):
            let (sx, sy) = scaled(x: x, y: y)
            await performScroll(x: sx, y: sy, direction: direction, amount: amount)

        case .mouseMove(let x, let y):
            let (sx, sy) = scaled(x: x, y: y)
            await performMouseMove(x: sx, y: sy)

        case .leftClickDrag(let startX, let startY, let endX, let endY):
            let (ssx, ssy) = scaled(x: startX, y: startY)
            let (sex, sey) = scaled(x: endX, y: endY)
            await performLeftClickDrag(startX: ssx, startY: ssy, endX: sex, endY: sey)

        case .screenshot:
            print("[ActionExecutor] Screenshot action - handled by main loop")

        case .cursorPosition:
            await printCursorPosition()
        }

        // Delay after each action to let UI update
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    }

    // MARK: - Mouse Actions

    private func performLeftClick(x: Int, y: Int) async {
        let point = CGPoint(x: x, y: y)

        // Move mouse to position first
        moveMouseTo(point: point)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay

        // Mouse down
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
        }

        // Mouse up
        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(x: Int, y: Int) async {
        let point = CGPoint(x: x, y: y)

        // Move mouse to position first
        moveMouseTo(point: point)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay

        // Mouse down
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            mouseDown.post(tap: .cghidEventTap)
        }

        // Mouse up
        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(x: Int, y: Int) async {
        let point = CGPoint(x: x, y: y)

        // Move mouse to position first
        moveMouseTo(point: point)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay

        // First click
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
            mouseDown.post(tap: .cghidEventTap)
        }

        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
            mouseUp.post(tap: .cghidEventTap)
        }

        // Second click
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            mouseDown.setIntegerValueField(.mouseEventClickState, value: 2)
            mouseDown.post(tap: .cghidEventTap)
        }

        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            mouseUp.setIntegerValueField(.mouseEventClickState, value: 2)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    private func performMiddleClick(x: Int, y: Int) async {
        let point = CGPoint(x: x, y: y)

        // Move mouse to position first
        moveMouseTo(point: point)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay

        // Mouse down
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: point, mouseButton: .center) {
            mouseDown.post(tap: .cghidEventTap)
        }

        // Mouse up
        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: point, mouseButton: .center) {
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    private func performMouseMove(x: Int, y: Int) async {
        let point = CGPoint(x: x, y: y)
        moveMouseTo(point: point)
    }

    private func moveMouseTo(point: CGPoint) {
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    private func performLeftClickDrag(startX: Int, startY: Int, endX: Int, endY: Int) async {
        let startPoint = CGPoint(x: startX, y: startY)
        let endPoint = CGPoint(x: endX, y: endY)

        // Move to start position
        moveMouseTo(point: startPoint)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Mouse down at start
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
        }

        // Interpolate drag movement — 10 intermediate points
        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let ix = Double(startX) + t * Double(endX - startX)
            let iy = Double(startY) + t * Double(endY - startY)
            let point = CGPoint(x: ix, y: iy)
            if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                dragEvent.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms between steps
        }

        // Mouse up at end
        if let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left) {
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard Actions

    private func performType(text: String) async {
        // Save current pasteboard contents
        let pasteboard = NSPasteboard.general
        let savedContents = pasteboard.pasteboardItems?.map { item -> (String, String)? in
            if let type = item.types.first, let data = item.string(forType: type) {
                return (type.rawValue, data)
            }
            return nil
        }.compactMap { $0 }

        // Set pasteboard to target text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let vKeyCode: CGKeyCode = 0x09 // V key

        // Key down with Command modifier
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }

        // Wait for paste to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Restore original pasteboard contents
        if let savedContents = savedContents, !savedContents.isEmpty {
            pasteboard.clearContents()
            for (type, data) in savedContents {
                pasteboard.setString(data, forType: NSPasteboard.PasteboardType(type))
            }
        }
    }

    private func performKey(keys: String) async {
        // Parse space-separated key combos
        let keyCombos = keys.split(separator: " ").map { String($0) }

        for combo in keyCombos {
            await executeKeyCombo(combo)
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms between combos
        }
    }

    private func executeKeyCombo(_ combo: String) async {
        // Parse modifiers and key
        let parts = combo.split(separator: "+").map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        var modifiers: CGEventFlags = []
        var keyCode: CGKeyCode?

        for part in parts {
            switch part {
            case "cmd", "command", "super":
                modifiers.insert(.maskCommand)
            case "ctrl", "control":
                modifiers.insert(.maskControl)
            case "alt", "option":
                modifiers.insert(.maskAlternate)
            case "shift":
                modifiers.insert(.maskShift)
            default:
                // This should be the key itself
                keyCode = mapKeyName(part)
            }
        }

        guard let keyCode = keyCode else {
            print("[ActionExecutor] Unknown key in combo: \(combo)")
            return
        }

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = modifiers
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = modifiers
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func mapKeyName(_ name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "return", "enter":
            return 0x24
        case "tab":
            return 0x30
        case "escape", "esc":
            return 0x35
        case "space":
            return 0x31
        case "backspace", "delete":
            return 0x33
        case "up":
            return 0x7E
        case "down":
            return 0x7D
        case "left":
            return 0x7B
        case "right":
            return 0x7C
        // Single character keys
        case "a":
            return 0x00
        case "b":
            return 0x0B
        case "c":
            return 0x08
        case "d":
            return 0x02
        case "e":
            return 0x0E
        case "f":
            return 0x03
        case "g":
            return 0x05
        case "h":
            return 0x04
        case "i":
            return 0x22
        case "j":
            return 0x26
        case "k":
            return 0x28
        case "l":
            return 0x25
        case "m":
            return 0x2E
        case "n":
            return 0x2D
        case "o":
            return 0x1F
        case "p":
            return 0x23
        case "q":
            return 0x0C
        case "r":
            return 0x0F
        case "s":
            return 0x01
        case "t":
            return 0x11
        case "u":
            return 0x20
        case "v":
            return 0x09
        case "w":
            return 0x0D
        case "x":
            return 0x07
        case "y":
            return 0x10
        case "z":
            return 0x06
        default:
            return nil
        }
    }

    // MARK: - Scroll Action

    private func performScroll(x: Int, y: Int, direction: String, amount: Int) async {
        let point = CGPoint(x: x, y: y)

        // Move mouse to position first
        moveMouseTo(point: point)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay

        var scrollX: Int32 = 0
        var scrollY: Int32 = 0

        switch direction.lowercased() {
        case "up":
            scrollY = Int32(amount)
        case "down":
            scrollY = -Int32(amount)
        case "left":
            scrollX = Int32(amount)
        case "right":
            scrollX = -Int32(amount)
        default:
            print("[ActionExecutor] Unknown scroll direction: \(direction)")
            return
        }

        // Create scroll event
        if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: scrollY, wheel2: scrollX, wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Utility

    private func printCursorPosition() async {
        if let position = CGEvent(source: nil)?.location {
            print("[ActionExecutor] Cursor position: (\(Int(position.x)), \(Int(position.y)))")
        } else {
            print("[ActionExecutor] Could not get cursor position")
        }
    }
}
