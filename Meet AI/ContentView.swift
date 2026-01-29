import Foundation
import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

// MARK: - Main view for the application

struct ContentView: View {
    @State private var userInput = ""
    @State private var response = "Ask me anything..."

    var body: some View {
        VStack(spacing: 12) {
            Text("AI Assistant")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading) {
                    Text(response)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

            TextField("Type your question", text: $userInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .submitLabel(.send)
                .onSubmit {
                    askAI()
                }

            Button("Ask with Screenshot") {
                askAIWithScreenshot()
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button("Ask") {
                askAI()
            }
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .frame(width: 300)
        .shadow(radius: 8)
    }

    // Function to handle text-only questions
    func askAI() {
        guard !userInput.isEmpty else { return }
        response = "Thinking..."
        sendToGemini(prompt: userInput) { result in
            response = result
            userInput = ""
        }
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
