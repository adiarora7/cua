import Foundation
import AVFoundation
import WhisperKit

/// WhisperKit-based STT provider with fast VAD-based end-of-speech detection (~200ms).
/// Falls back gracefully if model download or init fails.
final class WhisperSTTProvider: @unchecked Sendable, STTProvider {
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private let logger: SessionLogger?

    /// Silence duration threshold (seconds) — how long silence must last to finalize speech.
    /// Much shorter than Apple STT's 1.2s.
    private let silenceThreshold: TimeInterval = 0.35
    /// Energy level below which we consider "silence".
    private let energyFloor: Float = 0.02

    init(logger: SessionLogger? = nil) {
        self.logger = logger
    }

    func setup() async -> Bool {
        guard featureEnabled("CUA_USE_WHISPER") else {
            logger?.log("[whisper-stt] CUA_USE_WHISPER not enabled")
            return false
        }

        do {
            let modelName = "small.en" // base.en is too inaccurate for conversational speech
            print("Downloading speech recognition model (\(modelName))...")
            logger?.log("[whisper-stt] initializing WhisperKit with \(modelName) model")
            let config = WhisperKitConfig(
                model: modelName,
                verbose: false,
                load: true
            )
            let kit = try await WhisperKit(config)
            self.whisperKit = kit

            // Verify tokenizer loaded (prewarm mode skips it, load: true should include it)
            if kit.tokenizer == nil {
                logger?.log("[whisper-stt] tokenizer not loaded, calling loadModels() explicitly")
                try await kit.loadModels()
            }
            guard kit.tokenizer != nil else {
                logger?.log("[whisper-stt] tokenizer still nil after loadModels()")
                return false
            }

            logger?.log("[whisper-stt] model loaded successfully (tokenizer ready)")
            print("Speech recognition model ready.")
            return true
        } catch {
            logger?.log("[whisper-stt] setup failed: \(error)")
            print("WhisperKit setup failed: \(error.localizedDescription)")
            return false
        }
    }

    func listen(onStablePartial: (@Sendable (String) -> Void)?) async -> String? {
        guard let whisperKit = whisperKit else { return nil }

        // Use WhisperKit's AudioStreamTranscriber for real-time streaming
        let startTime = ContinuousClock.now

        // State tracking (protected by actor isolation of AudioStreamTranscriber)
        let stateBox = StateBox()

        do {
            guard let tokenizer = whisperKit.tokenizer else {
                logger?.log("[whisper-stt] tokenizer not available")
                return nil
            }

            let decodingOptions = DecodingOptions(
                language: "en",
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: false
            )

            let transcriber = AudioStreamTranscriber(
                audioEncoder: whisperKit.audioEncoder,
                featureExtractor: whisperKit.featureExtractor,
                segmentSeeker: whisperKit.segmentSeeker,
                textDecoder: whisperKit.textDecoder,
                tokenizer: tokenizer,
                audioProcessor: whisperKit.audioProcessor,
                decodingOptions: decodingOptions,
                requiredSegmentsForConfirmation: 2,
                silenceThreshold: 0.3, // WhisperKit's default — used for internal VAD voice detection
                useVAD: true,
                stateChangeCallback: { oldState, newState in
                    // Track state changes for end-of-speech detection
                    let currentText = newState.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let confirmedText = newState.confirmedSegments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    let fullText = confirmedText.isEmpty ? currentText : (currentText.isEmpty ? confirmedText : confirmedText + " " + currentText)

                    // Filter out WhisperKit's internal placeholder text
                    let isPlaceholder = fullText == "Waiting for speech..." ||
                                        fullText.hasPrefix("Waiting for speech")

                    if !fullText.isEmpty && !isPlaceholder {
                        stateBox.updateText(fullText)

                        // Show partial transcription
                        print("\r\u{1B}[2K  \(fullText)", terminator: "")
                        fflush(stdout)
                    }

                    // Check energy for silence detection
                    let recentEnergy = newState.bufferEnergy.suffix(3) // Last ~300ms
                    let isSilent = !recentEnergy.isEmpty && recentEnergy.allSatisfy { $0 < 0.02 }

                    if isSilent && !fullText.isEmpty && !isPlaceholder {
                        stateBox.markSilence()
                    } else if !isSilent {
                        stateBox.clearSilence()
                    }
                }
            )

            self.streamTranscriber = transcriber

            // startStreamTranscription() blocks until stopStreamTranscription() is called
            // (it runs realtimeLoop() internally), so launch it in a background Task.
            let transcriptionTask = Task {
                try await transcriber.startStreamTranscription()
            }

            // Poll for end-of-speech or timeout
            let noSpeechTimeout: TimeInterval = 60.0
            let pollInterval: UInt64 = 50_000_000 // 50ms

            while true {
                try await Task.sleep(nanoseconds: pollInterval)

                if Task.isCancelled {
                    await transcriber.stopStreamTranscription()
                    transcriptionTask.cancel()
                    self.streamTranscriber = nil
                    return stateBox.bestText
                }

                let elapsed = Double((ContinuousClock.now - startTime).components.attoseconds) / 1_000_000_000_000_000_000

                // Timeout with no speech
                if elapsed > noSpeechTimeout && stateBox.bestText == nil {
                    await transcriber.stopStreamTranscription()
                    transcriptionTask.cancel()
                    self.streamTranscriber = nil
                    return nil
                }

                // Check if silence threshold exceeded (end-of-speech)
                if let silenceStart = stateBox.silenceStart, stateBox.bestText != nil {
                    let silenceDuration = Double((ContinuousClock.now - silenceStart).components.attoseconds) / 1_000_000_000_000_000_000
                    if silenceDuration >= silenceThreshold {
                        let endOfSpeechMs = Int(silenceDuration * 1000)
                        logger?.log("[perf] stt_end_of_speech \(endOfSpeechMs)ms (whisper)")

                        // Fire onStablePartial if not already fired
                        if let text = stateBox.bestText, !stateBox.stableCallbackFired {
                            stateBox.stableCallbackFired = true
                            DispatchQueue.global(qos: .userInitiated).async {
                                onStablePartial?(text)
                            }
                        }

                        print("") // newline after partial
                        await transcriber.stopStreamTranscription()
                        transcriptionTask.cancel()
                        self.streamTranscriber = nil
                        return stateBox.bestText
                    }
                }

                // Fire stable partial callback after 500ms of stable text
                if let text = stateBox.bestText, !stateBox.stableCallbackFired {
                    if let lastChange = stateBox.lastTextChange {
                        let textStable = Double((ContinuousClock.now - lastChange).components.attoseconds) / 1_000_000_000_000_000_000
                        if textStable >= 0.5 {
                            stateBox.stableCallbackFired = true
                            let capturedText = text
                            DispatchQueue.global(qos: .userInitiated).async {
                                onStablePartial?(capturedText)
                            }
                        }
                    }
                }
            }
        } catch {
            logger?.log("[whisper-stt] listen error: \(error)")
            if let t = streamTranscriber {
                await t.stopStreamTranscription()
            }
            self.streamTranscriber = nil
            return nil
        }
    }

    func stopListening() async {
        if let transcriber = streamTranscriber {
            await transcriber.stopStreamTranscription()
            streamTranscriber = nil
        }
    }
}

/// Thread-safe state tracking for the stream transcription callback.
private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _bestText: String?
    private var _silenceStart: ContinuousClock.Instant?
    private var _lastTextChange: ContinuousClock.Instant?
    var stableCallbackFired = false

    var bestText: String? {
        lock.lock(); defer { lock.unlock() }
        return _bestText
    }

    var silenceStart: ContinuousClock.Instant? {
        lock.lock(); defer { lock.unlock() }
        return _silenceStart
    }

    var lastTextChange: ContinuousClock.Instant? {
        lock.lock(); defer { lock.unlock() }
        return _lastTextChange
    }

    func updateText(_ text: String) {
        lock.lock()
        if _bestText != text {
            _bestText = text
            _lastTextChange = ContinuousClock.now
            stableCallbackFired = false
        }
        lock.unlock()
    }

    func markSilence() {
        lock.lock()
        if _silenceStart == nil {
            _silenceStart = ContinuousClock.now
        }
        lock.unlock()
    }

    func clearSilence() {
        lock.lock()
        _silenceStart = nil
        lock.unlock()
    }
}
