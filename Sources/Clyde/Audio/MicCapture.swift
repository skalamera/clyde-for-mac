import Foundation
import AVFAudio
import AVFoundation

/// Captures the user's own microphone, separately from `SystemAudioTap`. Kept as an
/// independent stream (rather than mixed with system audio) so speaker attribution ("You" vs
/// "Them") falls out for free — the meeting app never renders the user's own mic back to the
/// output device, so the system-audio tap is inherently echo-free; this stream is the one that
/// can hear the speakers, which is why voice processing (echo cancellation) matters here.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let bufferHandler: (AVAudioPCMBuffer, AVAudioTime) -> Void
    private(set) var hasObservedNonSilentAudio = false

    init(bufferHandler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.bufferHandler = bufferHandler
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDeviceAuthorizer.requestMicrophoneAccess()
    }

    func start() throws {
        let input = engine.inputNode

        // Must be enabled before the engine starts. Provides system-level acoustic echo
        // cancellation so speaker output picked up by the mic (when not on headphones) is
        // suppressed rather than polluting the "You" transcript with the other side's audio.
        try input.setVoiceProcessingEnabled(true)

        // Voice processing (AEC) ducks other system audio by default — even at its default
        // (non-"advanced") level, per Apple's own docs — which is why enabling it noticeably
        // lowers whatever else is playing (e.g. the meeting app's own audio) the moment a
        // meeting starts. Explicitly dial that down to its minimum; we still want the actual
        // echo cancellation, just not the audio-ducking side effect.
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )

        // With voice processing enabled, some Macs report the input node's native format as
        // many-channel (e.g. 7ch) raw microphone-array data rather than a clean processed
        // signal — the actual echo-cancelled voice isn't reliably on channel 0 of that. Instead
        // of reading the native format directly, request MONO explicitly: AVAudioEngine then
        // performs its own internal downmix from the native voice-processed output to a single
        // clean channel before the tap ever sees it, rather than this code having to guess which
        // of several raw channels holds the real signal.
        let nativeFormat = input.outputFormat(forBus: 0)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeFormat.sampleRate, channels: 1, interleaved: false) else {
            throw AudioTapError.missingFormat
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            if !self.hasObservedNonSilentAudio, let channelData = buffer.floatChannelData {
                let frameCount = Int(buffer.frameLength)
                var sumOfSquares: Float = 0
                let samples = channelData[0]
                for i in 0..<frameCount { sumOfSquares += samples[i] * samples[i] }
                let rms = frameCount > 0 ? (sumOfSquares / Float(frameCount)).squareRoot() : 0
                if rms > 0.0001 { self.hasObservedNonSilentAudio = true }
            }
            self.bufferHandler(buffer, time)
        }

        engine.prepare()
        try engine.start()
        Log.audio.info("Microphone capture started (format: \(format.sampleRate, privacy: .public)Hz, \(format.channelCount, privacy: .public)ch)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Thin wrapper so mic-permission logic lives in one place; kept separate from AVFoundation's
/// camera-oriented naming.
enum AVCaptureDeviceAuthorizer {
    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            default:
                continuation.resume(returning: false)
            }
        }
    }
}
