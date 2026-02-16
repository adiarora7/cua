import Foundation
import AVFoundation
import Speech

/// Abstraction for speech-to-text backends. Interchangeable between Apple STT and WhisperKit.
protocol STTProvider: Sendable {
    /// Initialize the provider. Returns true if ready.
    func setup() async -> Bool
    /// Listen for speech. Returns final transcription or nil if no speech / interrupted.
    /// `onStablePartial` fires when partial text hasn't changed for ~500ms.
    func listen(onStablePartial: (@Sendable (String) -> Void)?) async -> String?
    /// Stop listening. Awaitable — returns only after audio tap removed and engine stopped.
    func stopListening() async
}

/// Apple SFSpeechRecognizer-based STT provider. Extracted from VoiceManager.
final class AppleSTTProvider: @unchecked Sendable, STTProvider {
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let logger: SessionLogger?

    private let silenceTimeout: TimeInterval = 1.2
    private let noSpeechTimeout: TimeInterval = 60.0

    init(logger: SessionLogger? = nil) {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.logger = logger
    }

    func setup() async -> Bool {
        guard speechRecognizer?.isAvailable == true else {
            logger?.log("[apple-stt] speech recognizer not available")
            return false
        }
        return true
    }

    func listen(onStablePartial: (@Sendable (String) -> Void)?) async -> String? {
        await stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode

        // Pass nil for format — lets AVFAudio use the hardware's native format
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("Error starting audio engine: \(error)")
            logger?.log("[apple-stt error] audio engine start: \(error)")
            return nil
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var bestText: String?
            var silenceTimer: DispatchWorkItem?
            var noSpeechTimer: DispatchWorkItem?
            var stabilityTimer: DispatchWorkItem?
            var stableCallbackFired = false
            var lastPartialText: String?
            var finished = false

            let finish = { (text: String?) in
                guard !finished else { return }
                finished = true
                silenceTimer?.cancel()
                noSpeechTimer?.cancel()
                stabilityTimer?.cancel()
                Task { await self.stopListening() }
                cont.resume(returning: text)
            }

            let nsTimer = DispatchWorkItem { finish(nil) }
            noSpeechTimer = nsTimer
            DispatchQueue.main.asyncAfter(deadline: .now() + self.noSpeechTimeout, execute: nsTimer)

            self.recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
                if let result = result {
                    bestText = result.bestTranscription.formattedString

                    print("\r\u{1B}[2K  \(bestText ?? "")", terminator: "")
                    fflush(stdout)

                    // Fire onStablePartial when text hasn't changed for 500ms
                    if let bt = bestText, !stableCallbackFired, onStablePartial != nil {
                        if bt != lastPartialText {
                            lastPartialText = bt
                            stabilityTimer?.cancel()
                            let capturedText = bt
                            let st = DispatchWorkItem {
                                guard !stableCallbackFired, !finished else { return }
                                stableCallbackFired = true
                                DispatchQueue.global(qos: .userInitiated).async {
                                    onStablePartial?(capturedText)
                                }
                            }
                            stabilityTimer = st
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: st)
                        }
                    }

                    noSpeechTimer?.cancel()

                    silenceTimer?.cancel()
                    let st = DispatchWorkItem {
                        print("")
                        finish(bestText)
                    }
                    silenceTimer = st
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.silenceTimeout, execute: st)

                    if result.isFinal {
                        print("")
                        finish(bestText)
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    if nsError.code == 216 || nsError.code == 301 {
                        // cancelled — expected
                    } else if nsError.code == 209 || nsError.code == 1110 {
                        // No speech detected
                    } else {
                        print("\r\u{1B}[2K  STT error: \(error.localizedDescription)")
                        self.logger?.log("[apple-stt error] \(error)")
                    }
                    finish(bestText)
                }
            }
        }
    }

    func stopListening() async {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}
