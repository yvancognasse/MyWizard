import AVFoundation

enum MicrophoneAuthorization {
    nonisolated static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                    continuation.resume(returning: granted)
                }
            }
        default: return false
        }
    }
}
