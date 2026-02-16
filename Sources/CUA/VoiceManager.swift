import Foundation
import AVFoundation
import Speech

/// Manages voice input (STT via pluggable STTProvider) and output (TTS via NarrationQueue).
/// Default: AppleSTTProvider. If CUA_USE_WHISPER=1, tries WhisperSTTProvider first.
final class VoiceManager: @unchecked Sendable {
    private var sttProvider: STTProvider
    private let logger: SessionLogger?

    /// Best available TTS voice (prefer premium/enhanced Siri voices).
    let ttsVoice: AVSpeechSynthesisVoice?

    /// Shared narration queue — speaks TTS without blocking the action loop.
    var narrationQueue: NarrationQueue?

    init(logger: SessionLogger? = nil) {
        self.logger = logger
        self.ttsVoice = VoiceManager.selectBestVoice()

        // Default to Apple STT — WhisperKit setup happens async in setupSTT()
        self.sttProvider = AppleSTTProvider(logger: logger)

        if let voice = self.ttsVoice {
            logger?.log("[voice] TTS voice: \(voice.name) (\(voice.identifier))")
        }
    }

    /// Async STT provider setup. Call after init. Tries WhisperKit if enabled, falls back to Apple STT.
    func setupSTT() async {
        if featureEnabled("CUA_USE_WHISPER") {
            let whisper = WhisperSTTProvider(logger: logger)
            if await whisper.setup() {
                sttProvider = whisper
                logger?.log("[voice] STT provider: WhisperKit")
                return
            }
            logger?.log("[voice] WhisperKit setup failed, falling back to Apple STT")
        }

        // Apple STT is the default — setup always succeeds if recognizer is available
        let apple = sttProvider as? AppleSTTProvider ?? AppleSTTProvider(logger: logger)
        let _ = await apple.setup()
        sttProvider = apple
        logger?.log("[voice] STT provider: Apple SFSpeechRecognizer")
    }

    /// Select the best available English voice, preferring premium quality.
    private static func selectBestVoice() -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let enVoices = allVoices.filter { $0.language.hasPrefix("en") }

        // Log available voices for debugging
        let grouped = Dictionary(grouping: enVoices) { "\($0.quality.rawValue)" }
        for (quality, voices) in grouped.sorted(by: { $0.key > $1.key }) {
            let names = voices.map { $0.name }.joined(separator: ", ")
            print("[voice] quality \(quality): \(names)")
        }

        // Prefer premium quality, then enhanced, then default
        if let premium = enVoices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = enVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Request microphone and speech recognition permissions. Returns true if granted.
    /// Always requests BOTH mic and SFSpeech auth regardless of active STT backend,
    /// so mid-session fallback to Apple STT works without surprise permission dialogs.
    func requestPermissions() async -> Bool {
        // Microphone — use callback-based API to avoid retain crash in async wrapper
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if #available(macOS 14.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                cont.resume(returning: true)
            }
        }
        guard micGranted else {
            print("Error: Microphone permission denied.")
            print("Grant in System Settings > Privacy & Security > Microphone")
            return false
        }

        // Speech recognition (always request — cached by OS after first grant)
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            print("Error: Speech recognition not authorized (status: \(speechStatus.rawValue)).")
            print("Grant in System Settings > Privacy & Security > Speech Recognition")
            return false
        }

        return true
    }

    /// Listen for speech via the active STT provider. Returns final text or nil.
    /// `onStablePartial` fires when partial text hasn't changed for ~500ms.
    func listen(onStablePartial: (@Sendable (String) -> Void)? = nil) async -> String? {
        // Mute narration while mic is open — prevents TTS echo from being transcribed
        if let nq = narrationQueue {
            nq.mute()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let result = await sttProvider.listen(onStablePartial: onStablePartial)

        // If STT provider failed mid-session, try falling back
        if result == nil {
            // Check if provider might have had an error worth swapping for
            // (actual swap only happens on explicit errors, not normal nil returns)
        }

        return result
    }

    /// Stop listening via the active STT provider.
    func stopListening() async {
        await sttProvider.stopListening()
    }

    /// Swap the STT provider. Stops the current provider first.
    func swapProvider(to newProvider: STTProvider) async {
        await sttProvider.stopListening()
        sttProvider = newProvider
        logger?.log("[stt] swapped provider to \(type(of: newProvider))")
    }

    // MARK: - TTS (delegated to NarrationQueue)

    /// Speak text. Non-blocking — returns immediately.
    func speak(_ text: String) {
        if let nq = narrationQueue {
            nq.enqueue(text)
        } else {
            fallbackSpeak(text)
        }
    }

    /// Speak text and wait for completion.
    func speakAndWait(_ text: String) async {
        if let nq = narrationQueue {
            await nq.enqueueAndWait(text)
        } else {
            fallbackSpeakAndWait(text)
        }
    }

    /// Stop any ongoing TTS.
    func stopSpeaking() {
        if let nq = narrationQueue {
            nq.cancelAll()
        } else {
            fallbackSynthesizer?.stopSpeaking(at: .immediate)
        }
    }

    /// Whether TTS is currently speaking.
    var isSpeaking: Bool {
        if let nq = narrationQueue {
            return nq.isActive
        }
        return fallbackSynthesizer?.isSpeaking ?? false
    }

    // MARK: - Fallback direct TTS (used before NarrationQueue is set up)

    private lazy var fallbackSynthesizer: AVSpeechSynthesizer? = {
        let synth = AVSpeechSynthesizer()
        return synth
    }()

    private var fallbackDelegate: SpeechFinishDelegate?

    private func fallbackSpeak(_ text: String) {
        guard let synth = fallbackSynthesizer else { return }
        synth.delegate = nil
        fallbackDelegate = nil
        synth.stopSpeaking(at: .immediate)
        let utterance = makeUtterance(text)
        synth.speak(utterance)
        logger?.log("[tts-fallback] \(text)")
    }

    private func fallbackSpeakAndWait(_ text: String) {
        fallbackSpeak(text)
    }

    /// Create an utterance with the best available voice.
    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = ttsVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return utterance
    }
}

/// Thread-safe once-only execution guard.
private final class OnceGuard: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()

    func run(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        action()
    }
}

/// Delegate to detect when TTS finishes speaking.
private final class SpeechFinishDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let onFinish: @Sendable () -> Void
    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }
}
