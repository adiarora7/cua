import Foundation
import AVFoundation

/// Kokoro neural TTS backend using mlx-audio-swift (Soprano-80M model).
/// Currently blocked by swift-transformers version conflict between WhisperKit and mlx-audio-swift.
/// TTSBackend protocol is in place — activate when dependency versions align.
///
/// To enable: add mlx-audio-swift to Package.swift, uncomment imports, set CUA_USE_KOKORO=1.
///
/// Expected model: mlx-community/Soprano-80M-bf16 (~330MB download)
/// Expected performance: ~3.3x realtime on M2 MacBook Air
final class KokoroTTSBackend: @unchecked Sendable, TTSBackend {
    private let logger: SessionLogger?
    private var audioPlayer: AVAudioPlayer?
    private var completionHandler: (@Sendable () -> Void)?
    private var _isSpeaking = false

    init(logger: SessionLogger? = nil) {
        self.logger = logger
    }

    /// Download and initialize the Soprano model.
    /// Returns false if CUA_USE_KOKORO is not set or model download fails.
    func setup() async -> Bool {
        guard featureEnabled("CUA_USE_KOKORO") else {
            logger?.log("[kokoro-tts] CUA_USE_KOKORO not enabled")
            return false
        }

        // TODO: When mlx-audio-swift dependency resolves:
        // 1. import MLXAudioTTS
        // 2. let model = try await SopranoModel.fromPretrained("mlx-community/Soprano-80M-bf16")
        // 3. Store model for generate() calls
        logger?.log("[kokoro-tts] not available — mlx-audio-swift dependency not resolved")
        print("[Kokoro TTS] Not available — dependency conflict. Using system TTS.")
        return false
    }

    func speak(_ text: String, completion: @escaping @Sendable () -> Void) {
        // TODO: When model is available:
        // 1. let audio = try await model.generate(text: text)
        // 2. Play audio via AVAudioPlayer
        // 3. Call completion when playback finishes
        completionHandler = completion
        _isSpeaking = true
        logger?.log("[kokoro-tts] speak: \(text)")

        // Fallback: immediate completion (no-op since setup returns false)
        _isSpeaking = false
        completion()
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        _isSpeaking = false
        completionHandler = nil
    }

    var isSpeaking: Bool {
        _isSpeaking
    }
}
