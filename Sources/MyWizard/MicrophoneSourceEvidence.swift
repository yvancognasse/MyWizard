import AVFoundation
import Foundation

// Source energy is evidence, not biometric identity. Classify whole voice
// clusters using clear single-speaker periods; never label every nonzero mic
// sample as the owner, and never delete a word because its origin is uncertain.
struct MicrophoneSourceEvidence {
    struct Window {
        let time: Double
        let systemPower: Double
        let microphonePower: Double
    }
    let windows: [Window]

    static func read(system: URL, microphone: URL?) throws -> Self {
        guard let microphone else { return Self(windows: []) }
        let files = try [AVAudioFile(forReading: system), AVAudioFile(forReading: microphone)]
        let length = files.map(\.length).max() ?? 0
        let buffer = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 1600)!
        var windows: [Window] = []
        var frame: Int64 = 0
        while frame < length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(1600, length - frame))
            var power = [Double](repeating: 0, count: 2)
            for (index, file) in files.enumerated() where file.framePosition < file.length {
                try file.read(into: buffer, frameCount: count)
                if let samples = buffer.floatChannelData?[0] {
                    for i in 0..<Int(buffer.frameLength) { power[index] += Double(samples[i]) * Double(samples[i]) }
                    power[index] /= Double(count)
                }
            }
            windows.append(Window(time: (Double(frame) + Double(count) / 2) / 16000,
                                  systemPower: power[0], microphonePower: power[1]))
            frame += Int64(count)
        }
        return Self(windows: windows)
    }

    func microphoneSlots(intervals: [SpeakerInterval]) -> Set<Int> {
        var own: [Int: Int] = [:], remote: [Int: Int] = [:]
        for window in windows {
            let slots = Set(intervals.filter { $0.start <= window.time && $0.end > window.time }.map(\.slot))
            guard slots.count == 1, let slot = slots.first else { continue }
            if window.microphonePower > 1e-7 && window.microphonePower >= window.systemPower * 4 {
                own[slot, default: 0] += 1
            } else if window.systemPower > 1e-7 && window.systemPower >= window.microphonePower * 4 {
                remote[slot, default: 0] += 1
            }
        }
        return Set(own.keys.filter { slot in
            // At least 0.5 s of clear local-source evidence and at least 80%
            // of the unambiguous source votes across the entire voice cluster.
            let local = own[slot, default: 0], other = remote[slot, default: 0]
            return local >= 5 && Double(local) / Double(local + other) >= 0.8
        })
    }
}
