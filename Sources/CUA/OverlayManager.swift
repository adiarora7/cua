import AppKit
import Foundation
import QuartzCore

/// Floating pill overlay that shows the agent's current state.
/// Frosted glass design with sine wave animation for listening mode.
final class OverlayManager: @unchecked Sendable {
    enum State: Sendable {
        case listening
        case thinking       // Opus planning/evaluating
        case understanding  // Opus interpreting voice intent
        case acting         // Sonnet executing actions
        case narrating      // Speaking while acting simultaneously
        case guiding        // Guiding user — showing highlight
        case speaking
        case idle

        var label: String {
            switch self {
            case .listening:     return "Listening"
            case .thinking:      return "Thinking"
            case .understanding: return "Understanding"
            case .acting:        return "Acting"
            case .narrating:     return "Narrating"
            case .guiding:       return "Look here"
            case .speaking:      return "Speaking"
            case .idle:          return "Ready"
            }
        }

        /// Accent color for dot and wave stroke
        var accentColor: CGColor {
            switch self {
            case .listening:     return CGColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1.0)
            case .thinking:      return CGColor(red: 0.58, green: 0.42, blue: 0.95, alpha: 1.0)
            case .understanding: return CGColor(red: 0.65, green: 0.38, blue: 0.92, alpha: 1.0)
            case .acting:        return CGColor(red: 0.38, green: 0.58, blue: 0.98, alpha: 1.0)
            case .narrating:     return CGColor(red: 0.32, green: 0.75, blue: 0.92, alpha: 1.0)
            case .guiding:       return CGColor(red: 0.98, green: 0.82, blue: 0.22, alpha: 1.0)
            case .speaking:      return CGColor(red: 0.98, green: 0.65, blue: 0.22, alpha: 1.0)
            case .idle:          return CGColor(gray: 0.55, alpha: 1.0)
            }
        }

        /// Subtle tint over the frosted glass
        var tintColor: CGColor {
            switch self {
            case .listening:     return CGColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.08)
            case .thinking:      return CGColor(red: 0.58, green: 0.42, blue: 0.95, alpha: 0.08)
            case .understanding: return CGColor(red: 0.65, green: 0.38, blue: 0.92, alpha: 0.08)
            case .acting:        return CGColor(red: 0.38, green: 0.58, blue: 0.98, alpha: 0.08)
            case .narrating:     return CGColor(red: 0.32, green: 0.75, blue: 0.92, alpha: 0.08)
            case .guiding:       return CGColor(red: 0.98, green: 0.82, blue: 0.22, alpha: 0.08)
            case .speaking:      return CGColor(red: 0.98, green: 0.65, blue: 0.22, alpha: 0.08)
            case .idle:          return CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
            }
        }

        /// Border color — accent at reduced opacity
        var borderColor: CGColor {
            switch self {
            case .listening:     return CGColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.35)
            case .thinking:      return CGColor(red: 0.58, green: 0.42, blue: 0.95, alpha: 0.35)
            case .understanding: return CGColor(red: 0.65, green: 0.38, blue: 0.92, alpha: 0.35)
            case .acting:        return CGColor(red: 0.38, green: 0.58, blue: 0.98, alpha: 0.35)
            case .narrating:     return CGColor(red: 0.32, green: 0.75, blue: 0.92, alpha: 0.35)
            case .guiding:       return CGColor(red: 0.98, green: 0.82, blue: 0.22, alpha: 0.35)
            case .speaking:      return CGColor(red: 0.98, green: 0.65, blue: 0.22, alpha: 0.35)
            case .idle:          return CGColor(gray: 1.0, alpha: 0.10)
            }
        }
    }

    private(set) var window: NSWindow?
    private var effectView: NSVisualEffectView?
    private var tintLayer: CALayer?
    private var textLayer: CATextLayer?
    private var dotLayer: CALayer?
    private var waveLayer: CAShapeLayer?
    private var currentState: State = .idle

    // Wave animation
    private var waveTimer: Timer?
    private var wavePhase: CGFloat = 0

    // Highlight for guiding the user
    private var highlightWindow: NSWindow?
    private var highlightGlowLayer: CALayer?
    private var highlightRipple1: CAShapeLayer?
    private var highlightRipple2: CAShapeLayer?

    private let pillWidth: CGFloat = 180
    private let pillHeight: CGFloat = 36

    init() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.setupWindow()
                self.setupHighlightWindow()
            }
        }
    }

    deinit {
        waveTimer?.invalidate()
    }

    /// Update the displayed state. Thread-safe.
    func setState(_ state: State) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.applyState(state, detail: nil) }
        }
    }

    /// Update with a custom detail string (e.g. "Block 2/4").
    func setState(_ state: State, detail: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.applyState(state, detail: detail) }
        }
    }

    @MainActor
    private func applyState(_ state: State, detail: String?) {
        let previousState = currentState
        currentState = state

        let text = detail != nil ? "\(state.label) · \(detail!)" : state.label

        // Animate tint and border colors
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        tintLayer?.backgroundColor = state.tintColor
        effectView?.layer?.borderColor = state.borderColor
        CATransaction.commit()

        // Text transition — slide up + crossfade
        if previousState != state || detail != nil {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = .fromBottom
            transition.duration = 0.25
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            textLayer?.add(transition, forKey: "textChange")
        }
        textLayer?.string = text

        // Swap between sine wave (listening) and pulsing dot (other states)
        if state == .listening {
            showWave()
        } else {
            hideWave()
        }

        // Dot accent color
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        dotLayer?.backgroundColor = state.accentColor
        CATransaction.commit()

        // Window visibility
        if state == .idle {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.window?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.window?.orderOut(nil)
                        self?.window?.alphaValue = 1
                    }
                }
            })
        } else {
            if previousState == .idle {
                window?.alphaValue = 0
                window?.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    self.window?.animator().alphaValue = 1
                })
            } else {
                window?.orderFrontRegardless()
            }
        }
    }

    // MARK: - Sine wave animation

    @MainActor
    private func showWave() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        waveLayer?.opacity = 1.0
        dotLayer?.opacity = 0.0
        CATransaction.commit()
        startWaveTimer()
    }

    @MainActor
    private func hideWave() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        waveLayer?.opacity = 0.0
        dotLayer?.opacity = 1.0
        CATransaction.commit()
        stopWaveTimer()
    }

    @MainActor
    private func startWaveTimer() {
        waveTimer?.invalidate()
        waveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickWave()
        }
    }

    @MainActor
    private func stopWaveTimer() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    /// Called at 60fps to update the sine wave path. Runs on main thread via Timer.
    private func tickWave() {
        wavePhase += 0.12
        guard let wave = waveLayer else { return }

        let w = wave.bounds.width
        let h = wave.bounds.height
        let midY = h / 2
        let amplitude: CGFloat = 5.0
        let frequency: CGFloat = 2.5

        let path = CGMutablePath()
        let steps = Int(w)
        for i in 0...steps {
            let x = CGFloat(i)
            let t = x / w
            // Envelope tapers amplitude at edges for a polished look
            let envelope = sin(t * .pi)
            let y = midY + sin(t * .pi * 2 * frequency + wavePhase) * amplitude * envelope
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wave.path = path
        CATransaction.commit()
    }

    // MARK: - Pill window setup

    @MainActor
    private func setupWindow() {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - pillWidth / 2
        let safeTop = screen.visibleFrame.maxY
        let y = safeTop - pillHeight - 6

        let frame = NSRect(x: x, y: y, width: pillWidth, height: pillHeight)

        let win = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .statusBar
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true

        // Frosted glass background
        let ev = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        ev.material = .hudWindow
        ev.blendingMode = .behindWindow
        ev.state = .active
        ev.wantsLayer = true
        ev.layer?.cornerRadius = pillHeight / 2
        ev.layer?.masksToBounds = true
        ev.layer?.borderWidth = 1.0
        ev.layer?.borderColor = State.idle.borderColor

        // Mask the vibrancy effect itself to the pill shape
        let maskImage = NSImage(size: NSSize(width: pillWidth, height: pillHeight), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: self.pillHeight / 2, yRadius: self.pillHeight / 2)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        ev.maskImage = maskImage

        win.contentView = ev
        self.effectView = ev

        // Subtle color tint overlay
        let tint = CALayer()
        tint.frame = CGRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        tint.backgroundColor = State.idle.tintColor
        ev.layer?.addSublayer(tint)
        self.tintLayer = tint

        // Sine wave shape layer (visible only during listening)
        let wave = CAShapeLayer()
        wave.frame = CGRect(x: 8, y: 0, width: 24, height: pillHeight)
        wave.strokeColor = CGColor(gray: 1.0, alpha: 0.85)
        wave.fillColor = nil
        wave.lineWidth = 1.5
        wave.lineCap = .round
        wave.lineJoin = .round
        wave.opacity = 0
        ev.layer?.addSublayer(wave)
        self.waveLayer = wave

        // Pulsing status dot (visible for non-listening active states)
        let dotSize: CGFloat = 6
        let dot = CALayer()
        dot.frame = CGRect(x: 17, y: (pillHeight - dotSize) / 2, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = State.idle.accentColor
        ev.layer?.addSublayer(dot)
        self.dotLayer = dot

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")

        // Text label
        let text = CATextLayer()
        text.frame = CGRect(x: 36, y: (pillHeight - 16) / 2, width: pillWidth - 48, height: 16)
        text.fontSize = 12.5
        text.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        text.foregroundColor = CGColor(gray: 1.0, alpha: 0.92)
        text.alignmentMode = .left
        text.truncationMode = .end
        text.contentsScale = screen.backingScaleFactor
        text.string = "Ready"
        ev.layer?.addSublayer(text)
        self.textLayer = text

        self.window = win
    }

    // MARK: - Highlight indicator for guidance mode

    private let highlightSize: CGFloat = 90

    /// Show a ripple highlight at screen coordinates (model coordinate space: origin top-left).
    func showHighlight(x: Int, y: Int) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.applyHighlight(x: x, y: y) }
        }
    }

    /// Hide the highlight with a fade-out.
    func hideHighlight() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    self.highlightWindow?.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.highlightWindow?.orderOut(nil)
                        }
                    }
                })
            }
        }
    }

    @MainActor
    private func applyHighlight(x: Int, y: Int) {
        guard let screen = NSScreen.main else { return }
        let size = highlightSize

        // Convert from model coordinates (origin top-left) to AppKit (origin bottom-left)
        let screenHeight = screen.frame.height
        let appKitX = CGFloat(x) - size / 2
        let appKitY = screenHeight - CGFloat(y) - size / 2

        highlightWindow?.setFrame(
            NSRect(x: appKitX, y: appKitY, width: size, height: size),
            display: true
        )

        // Fade in
        highlightWindow?.alphaValue = 0
        highlightWindow?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.highlightWindow?.animator().alphaValue = 1
        })

        // Restart ripple animations (staggered)
        startRipple(highlightRipple1, delay: 0)
        startRipple(highlightRipple2, delay: 1.0)
    }

    @MainActor
    private func startRipple(_ layer: CAShapeLayer?, delay: CFTimeInterval) {
        guard let layer = layer else { return }
        layer.removeAllAnimations()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1.15

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 2.0
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.beginTime = CACurrentMediaTime() + delay
        layer.add(group, forKey: "ripple")
    }

    @MainActor
    private func setupHighlightWindow() {
        let size = highlightSize
        let gold = CGColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 1.0)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .statusBar + 1
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        contentView.wantsLayer = true
        win.contentView = contentView

        // Ripple ring 1 — radiates outward and fades
        let ripple1 = CAShapeLayer()
        ripple1.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let inset1: CGFloat = 8
        ripple1.path = CGPath(ellipseIn: CGRect(x: inset1, y: inset1, width: size - inset1 * 2, height: size - inset1 * 2), transform: nil)
        ripple1.strokeColor = CGColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 0.6)
        ripple1.fillColor = nil
        ripple1.lineWidth = 1.5
        ripple1.opacity = 0
        contentView.layer?.addSublayer(ripple1)
        self.highlightRipple1 = ripple1

        // Ripple ring 2 — staggered by half the period
        let ripple2 = CAShapeLayer()
        ripple2.frame = ripple1.frame
        ripple2.path = ripple1.path
        ripple2.strokeColor = ripple1.strokeColor
        ripple2.fillColor = nil
        ripple2.lineWidth = 1.5
        ripple2.opacity = 0
        contentView.layer?.addSublayer(ripple2)
        self.highlightRipple2 = ripple2

        // Center glow — soft circle with shadow halo
        let glowSize: CGFloat = 28
        let glow = CALayer()
        glow.frame = CGRect(x: (size - glowSize) / 2, y: (size - glowSize) / 2, width: glowSize, height: glowSize)
        glow.cornerRadius = glowSize / 2
        glow.backgroundColor = CGColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 0.22)
        glow.borderWidth = 1.5
        glow.borderColor = CGColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 0.65)
        glow.shadowColor = gold
        glow.shadowRadius = 14
        glow.shadowOpacity = 0.5
        glow.shadowOffset = .zero
        contentView.layer?.addSublayer(glow)
        self.highlightGlowLayer = glow

        // Gentle breathing pulse on the glow
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.92
        breathe.toValue = 1.08
        breathe.duration = 1.5
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breathe, forKey: "breathe")

        self.highlightWindow = win
        win.orderOut(nil)
    }
}
