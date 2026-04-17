import Foundation
import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

// MARK: - Main view for the application

struct ContentView: View {
    enum AssistantMode: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case agent = "Agent"

        var id: String { rawValue }
    }

    @State private var userInput = ""
    @State private var response = "Ask me anything..."
    @State private var selectedMode: AssistantMode = .chat
    @StateObject private var audioCaptureManager = AudioCaptureManager()
    @StateObject private var proactiveAgentManager = ProactiveAgentManager()

    var body: some View {
        VStack(spacing: 12) {
            Text("AI Assistant")
                .font(.headline)

            Picker("Mode", selection: $selectedMode) {
                ForEach(AssistantMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading) {
                    MarkdownResponseView(markdown: response)
                        .padding(.bottom, 4)

                    HStack {
                        Spacer()
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(response, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .frame(height: 200)
            .background(Color.black.opacity(0.1))
            .cornerRadius(10)

            HStack(spacing: 8) {
                TextField("Type your question", text: $userInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .submitLabel(.send)
                    .onSubmit {
                        askAI()
                    }

                Button(action: {
                    toggleAudioRecording()
                }) {
                    Image(systemName: audioCaptureManager.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(audioCaptureManager.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .help(audioCaptureManager.isRecording ? "Stop recording and send transcript to Gemini" : "Record laptop audio and microphone")
                .disabled(audioCaptureManager.isProcessing)
            }

            Button("Ask with Screenshot") {
                askAIWithScreenshot()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(audioCaptureManager.isRecording || audioCaptureManager.isProcessing)

            Button("Ask") {
                askAI()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(audioCaptureManager.isRecording || audioCaptureManager.isProcessing || proactiveAgentManager.isBusy)

            if selectedMode == .agent && proactiveAgentManager.hasPendingApproval {
                HStack(spacing: 8) {
                    Button(proactiveAgentManager.approvalButtonTitle) {
                        Task {
                            await proactiveAgentManager.approveCurrentAction()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reject") {
                        proactiveAgentManager.rejectCurrentAction()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .frame(width: 300)
        .shadow(radius: 8)
        .onReceive(proactiveAgentManager.$renderedOutput) { output in
            if selectedMode == .agent {
                response = output
            }
        }
    }

    // Function to handle text-only questions
    func askAI() {
        guard !userInput.isEmpty else { return }
        let request = userInput
        userInput = ""

        switch selectedMode {
        case .chat:
            response = "Thinking..."
            sendToGemini(prompt: request) { result in
                response = result
            }
        case .agent:
            Task {
                await proactiveAgentManager.submit(request: request)
            }
        }
    }

    func toggleAudioRecording() {
        Task {
            if audioCaptureManager.isRecording {
                await stopAudioRecordingAndSend()
            } else {
                await startAudioRecording()
            }
        }
    }

    func startAudioRecording() async {
        response = "Starting audio capture..."

        do {
            try await audioCaptureManager.startRecording()
            response = "Recording laptop audio and microphone. Press the mic button again to stop and send the transcript to Gemini."
        } catch {
            response = "❌ \(error.localizedDescription)"
        }
    }

    func stopAudioRecordingAndSend() async {
        response = "Transcribing audio..."

        do {
            let transcript = try await audioCaptureManager.stopRecording()
            let prompt = buildAudioPrompt(with: transcript)

            await MainActor.run {
                response = "Thinking with audio transcript..."
            }

            sendToGemini(prompt: prompt) { result in
                response = """
                Transcript:

                \(transcript)

                Gemini:

                \(result)
                """
                userInput = ""
            }
        } catch {
            response = "❌ \(error.localizedDescription)"
        }
    }

    func buildAudioPrompt(with transcript: String) -> String {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            return """
            You are receiving a transcript captured from the laptop audio and microphone. Please respond to it directly.

            Transcript:
            \(transcript)
            """
        }

        return """
        \(trimmedInput)

        Transcript captured from the laptop audio and microphone:
        \(transcript)
        """
    }

    // Function to handle questions with a screenshot
    func askAIWithScreenshot() {
        guard !userInput.isEmpty else {
            response = "Please type a question before taking a screenshot."
            return
        }
        response = "Capturing screenshot..."

        Task {
            // Call the async capture function
            let image = await captureScreenshotWithSCKit()

            guard let image = image, let base64 = base64String(from: image) else {
                await MainActor.run {
                    response = """
                    ❌ Failed to capture screenshot.
                    Tip: Please ensure Screen Recording permission is enabled for this app in
                    System Settings → Privacy & Security → Screen Recording.
                    """
                }
                return
            }

            await MainActor.run {
                response = "Thinking with screenshot..."
            }

            sendToGemini(prompt: userInput, imageBase64: base64) { result in
                DispatchQueue.main.async {
                    response = result
                    userInput = ""
                }
            }
        }
    }
}

struct MarkdownResponseView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block.kind {
                case .markdown(let text):
                    MarkdownTextBlockView(markdown: text)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownTextBlockView: View {
    let markdown: String

    private var parsedMarkdown: AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )
    }

    var body: some View {
        Group {
            if let parsedMarkdown {
                Text(parsedMarkdown)
            } else {
                Text(markdown)
            }
        }
        .font(.system(size: 14, weight: .regular, design: .rounded))
        .foregroundStyle(.primary)
        .lineSpacing(6)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String

    private var executableCommand: String? {
        TerminalCommandRunner.command(from: code, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text((language?.isEmpty == false ? language! : "code").uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                if let executableCommand {
                    Button(action: {
                        TerminalCommandRunner.run(command: executableCommand)
                    }) {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(code)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.95))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

struct MarkdownBlock: Identifiable {
    enum Kind {
        case markdown(String)
        case code(language: String?, code: String)
    }

    let id = UUID()
    let kind: Kind
}

enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let pattern = #"(?s)```([^\n`]*)\n(.*?)\n?```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [MarkdownBlock(kind: .markdown(markdown))]
        }

        let nsRange = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return [MarkdownBlock(kind: .markdown(markdown))]
        }

        var blocks: [MarkdownBlock] = []
        var currentIndex = markdown.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: markdown) else { continue }

            let leadingText = String(markdown[currentIndex..<matchRange.lowerBound])
            appendMarkdownBlock(leadingText, to: &blocks)

            let language = Range(match.range(at: 1), in: markdown).map {
                markdown[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let code = Range(match.range(at: 2), in: markdown).map {
                markdown[$0].trimmingCharacters(in: .newlines)
            } ?? ""

            blocks.append(MarkdownBlock(kind: .code(language: language, code: code)))
            currentIndex = matchRange.upperBound
        }

        let trailingText = String(markdown[currentIndex...])
        appendMarkdownBlock(trailingText, to: &blocks)

        return blocks.isEmpty ? [MarkdownBlock(kind: .markdown(markdown))] : blocks
    }

    private static func appendMarkdownBlock(_ text: String, to blocks: inout [MarkdownBlock]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        blocks.append(MarkdownBlock(kind: .markdown(text)))
    }
}

enum TerminalCommandRunner {
    private static let shellLanguages = Set(["bash", "sh", "shell", "zsh", "console", "terminal"])

    static func command(from code: String, language: String?) -> String? {
        let normalizedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let isPromptBlock = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("$ ") }
        guard shellLanguages.contains(normalizedLanguage ?? "") || isPromptBlock else {
            return nil
        }

        let cleaned = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$ ") {
                return String(trimmed.dropFirst(2))
            }
            return line
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    static func run(command: String) {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        guard let script = NSAppleScript(source: appleScript) else {
            NSSound.beep()
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            NSSound.beep()
        }
    }
}

// -----------------------------------------------------------------------------
// MARK: - API and Networking

func getAPIKey() -> String? {
    guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
          let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let key = plist["GEMINI_API_KEY"] as? String else {
        return nil
    }
    return key
}

// Function to send the request to the Google Gemini API
func sendToGemini(prompt: String, imageBase64: String? = nil, completion: @escaping (String) -> Void) {
    guard let apiKey = getAPIKey() else {
        completion("API Key not found in Secrets.plist. Please add it.")
        return
    }

    let model = "gemini-2.5-flash"
    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
        completion("Invalid URL.")
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    // Construct the request body
    var parts: [[String: Any]] = [["text": prompt]]
    if let imageStr = imageBase64 {
        parts.append(["inline_data": ["mime_type": "image/png", "data": imageStr]])
    }

    let requestBody: [String: Any] = ["contents": [["parts": parts]]]

    do {
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
    } catch {
        completion("Failed to encode request body: \(error.localizedDescription)")
        return
    }

    // Perform the network request
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            DispatchQueue.main.async {
                completion("Network request failed: \(error.localizedDescription)")
            }
            return
        }

        guard let data = data else {
            DispatchQueue.main.async {
                completion("No data received.")
            }
            return
        }

        // Parse the response structure
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let content = firstCandidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                DispatchQueue.main.async {
                    completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else if let errorJson = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let errorDict = errorJson["error"] as? [String: Any],
                      let message = errorDict["message"] as? String {
                DispatchQueue.main.async {
                    completion("API Error: \(message)")
                }
            } else {
                DispatchQueue.main.async {
                    let responseString = String(data: data, encoding: .utf8) ?? "Unreadable response"
                    completion("Failed to parse response. Check API key and quotas. Response: \(responseString)")
                }
            }
        } catch {
            DispatchQueue.main.async {
                completion("Failed to decode JSON response: \(error.localizedDescription)")
            }
        }
    }.resume()
}

// -----------------------------------------------------------------------------
// MARK: - Screen Capture and Image Handling

class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {

    // NOTE: Removed 'private' in the last step to allow access from the timeout closure.
    var continuation: CheckedContinuation<NSImage?, Never>?
    var hasCaptured = false
    var stream: SCStream?

    init(continuation: CheckedContinuation<NSImage?, Never>?) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard !hasCaptured, outputType == .screen else { return }
        hasCaptured = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            self.continuation?.resume(returning: nil)
            self.continuation = nil
            self.stopStream()
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        self.continuation?.resume(returning: image)
        self.continuation = nil
        self.stopStream()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
        if !hasCaptured {
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
    }

    // 🎯 FIX APPLIED HERE: Removed '@MainActor' to resolve the concurrency error.
    private func stopStream() {
        // Task is the bridge for using 'await' from a synchronous method.
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    // Public method to allow the external timeout logic to signal failure
    func signalTimeout() {
        if continuation != nil {
            print("⚠️ Timeout: Stopping stream and signaling failure.")
            continuation?.resume(returning: nil)
            continuation = nil
            stopStream()
        }
    }
}

func captureScreenshotWithSCKit() async -> NSImage? {
    // 1. Check macOS version support
    guard #available(macOS 13.0, *) else {
        print("❌ ScreenCaptureKit not supported on this macOS version.")
        return nil
    }

    // --- STEP 1: Perform the ASYNC setup work OUTSIDE the synchronous bridge ---
    let content: SCShareableContent
    do {
        // ✅ This ASYNC call is now correctly awaited in the outer async function.
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        print("❌ Screen capture failed during content fetching:", error.localizedDescription)
        // If permission is missing, this is where the error is caught.
        return nil
    }

    guard let display = content.displays.first else {
        print("❌ No display found.")
        return nil
    }

    // --- STEP 2: Use withCheckedContinuation for the delegate/stream output (The synchronous bridge) ---
    // The closure passed to this function MUST NOT contain 'await'.
    return await withCheckedContinuation { continuation in

        var handler: StreamOutputHandler? = nil

        // Timeout safeguard
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            handler?.signalTimeout()
            handler = nil
        }

        do {
            // All code below MUST be synchronous

            // 2. Configure stream
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 5

            // 3. Setup Handler and Stream (Synchronous calls)
            handler = StreamOutputHandler(continuation: continuation)

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: handler)

            handler?.stream = stream

            // 4. Start Capture (Synchronous call)
            try stream.addStreamOutput(handler!, type: .screen, sampleHandlerQueue: .main)
            stream.startCapture()

            print("✅ Screen capture started using ScreenCaptureKit")

        } catch {
            // This catches synchronous errors (e.g., config error)
            print("❌ Screen capture failed during stream setup:", error.localizedDescription)
            continuation.resume(returning: nil)
            handler = nil
        }
    }
}

func base64String(from image: NSImage) -> String? {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return nil
    }
    return pngData.base64EncodedString()
}
