import Foundation
@preconcurrency import AVFoundation

/// Mic capture. Pulls buffers off the default input and hands them to a sink.
@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Rough input level (0...1), for the overlay's waveform.
    var onLevel: (Float) -> Void = { _ in }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(sink: @escaping @MainActor (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Murmur", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input device available."
            ])
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // The engine reuses this buffer as soon as the tap returns, so take
            // our own copy before handing it to anything asynchronous.
            let level = Self.peak(of: buffer)
            guard let copy = Self.copy(buffer) else { return }
            Task { @MainActor in
                self?.onLevel(level)
                sink(copy)
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        onLevel(0)
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData,
              let destination = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: frames)
        }
        return copy
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            let sample = data[0][i]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        // Squash the dynamic range so quiet speech still moves the bars.
        return min(1, rms * 12)
    }
}
