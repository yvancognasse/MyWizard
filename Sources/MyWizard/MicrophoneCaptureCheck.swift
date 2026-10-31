import Foundation

// Explicit signed-app diagnostic. Captures for five seconds, logs only frame
// counts (never recognized text/audio), then stops. Diagnostic settings stay in memory.
enum MicrophoneCaptureCheck {
    @MainActor static func run() async throws {
        let defaults = MemoryPreferences()
        let model = TranscriptionModel(preferences: defaults)
        model.language = "en-US"
        await model.setMicrophoneEnabled(true)
        let cycles = min(3, max(1, Int(ProcessInfo.processInfo.environment["MYWIZARD_MICROPHONE_CHECK_CYCLES"] ?? "1") ?? 1))
        let seconds = min(60, max(5, Int(ProcessInfo.processInfo.environment["MYWIZARD_MICROPHONE_CHECK_SECONDS"] ?? "5") ?? 5))
        for cycle in 1...cycles {
        await model.toggleCapture()
        guard model.isCapturing else {
            throw TranscriptionError.message(model.errorMessage ?? "Capture did not start")
        }
        try await Task.sleep(for: .seconds(seconds))
        // Device/service startup can lag behind SCStream.startCapture returning.
        for _ in 0..<10 where model.capturedFrameCounts.microphone == 0 && model.isCapturing {
            try await Task.sleep(for: .seconds(1))
        }
        let counts = model.capturedFrameCounts
        if model.isCapturing { await model.toggleCapture() }
        guard counts.microphone > 0, model.errorMessage == nil, !model.isCapturing else {
            throw TranscriptionError.message(model.errorMessage ?? "No microphone frames received (system=\(counts.system), microphone=\(counts.microphone))")
        }
        print("MICROPHONE CAPTURE CHECK PASS: cycle=\(cycle), system frames=\(counts.system), microphone frames=\(counts.microphone); start and stop completed")
        }
        await model.shutDown()
    }
}
