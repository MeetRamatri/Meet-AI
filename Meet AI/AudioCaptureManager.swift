import Foundation
import AVFoundation
import ScreenCaptureKit
import Speech

@MainActor
final class AudioCaptureManager: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingURL: URL?
    private var recordingContinuation: CheckedContinuation<Void, Error>?

    func startRecording() async throws {
        guard !isRecording else { return }

        isProcessing = true
        defer { isProcessing = false }

        try await requestPermissions()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meet-ai-audio-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)

        try stream.addRecordingOutput(recordingOutput)
        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = recordingOutput
        self.recordingURL = url
        self.isRecording = true
    }

    func stopRecording() async throws -> String {
        guard isRecording else {
            throw AudioCaptureError.notRecording
        }

        guard let stream, let recordingURL else {
            throw AudioCaptureError.recordingUnavailable
        }

        isProcessing = true
        defer { isProcessing = false }

        isRecording = false
        self.stream = nil
        self.recordingOutput = nil
        self.recordingURL = nil

        try await stream.stopCapture()
        try await waitForRecordingToFinish()

        let transcript = try await transcribeAudio(at: recordingURL)
        try? FileManager.default.removeItem(at: recordingURL)

        guard !transcript.isEmpty else {
            throw AudioCaptureError.emptyTranscript
        }

        return transcript
    }

    private func requestPermissions() async throws {
        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneGranted else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus)
                }
            }

            guard status == .authorized else {
                throw AudioCaptureError.speechPermissionDenied
            }
        default:
            throw AudioCaptureError.speechPermissionDenied
        }
    }

    private func waitForRecordingToFinish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            recordingContinuation = continuation
        }
    }

    private func transcribeAudio(at url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw AudioCaptureError.speechRecognizerUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false

            var didResume = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error, !didResume {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal, !didResume else { return }
                didResume = true
                continuation.resume(returning: result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if task.state == .canceling || task.state == .completed, !didResume {
                didResume = true
                continuation.resume(throwing: AudioCaptureError.transcriptionFailed)
            }
        }
    }
}

extension AudioCaptureManager: @preconcurrency SCRecordingOutputDelegate {
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        recordingContinuation?.resume()
        recordingContinuation = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        recordingContinuation?.resume(throwing: error)
        recordingContinuation = nil
    }
}

enum AudioCaptureError: LocalizedError {
    case noDisplay
    case notRecording
    case recordingUnavailable
    case microphonePermissionDenied
    case speechPermissionDenied
    case speechRecognizerUnavailable
    case transcriptionFailed
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display was available for system audio capture."
        case .notRecording:
            return "Audio recording has not started yet."
        case .recordingUnavailable:
            return "The current recording could not be found."
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable it in System Settings -> Privacy & Security -> Microphone."
        case .speechPermissionDenied:
            return "Speech recognition access was denied. Enable it in System Settings -> Privacy & Security -> Speech Recognition."
        case .speechRecognizerUnavailable:
            return "Speech recognition is currently unavailable on this Mac."
        case .transcriptionFailed:
            return "The recorded audio could not be transcribed."
        case .emptyTranscript:
            return "No speech was detected in the recording."
        }
    }
}
