import Foundation
import AppKit

@MainActor
final class ProactiveAgentManager: ObservableObject {
    @Published private(set) var renderedOutput = "Ask me anything..."
    @Published private(set) var isBusy = false
    @Published private(set) var hasPendingApproval = false
    @Published private(set) var approvalButtonTitle = "Approve Action"
    @Published private(set) var taskState: AgentPublicState?

    private let backendClient = AgentBackendClient()

    private var activeConversationId: String?
    private var activeUserGoal: String?
    private var loopIteration = 0
    private var awaitingUserReply = false
    private var pendingAction: AgentExecutableAction?
    private var actionSummaries: [String] = []
    private var interactionHistory: [AgentHistoryEntry] = []

    func submit(request: String) async {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else { return }

        if awaitingUserReply {
            awaitingUserReply = false
            await continueAgentLoop(
                input: mergedInputForUserReply(trimmedRequest),
                lastActionResult: nil
            )
            return
        }

        resetSession()
        activeUserGoal = trimmedRequest
        await continueAgentLoop(input: trimmedRequest, lastActionResult: nil)
    }

    func approveCurrentAction() async {
        guard let pendingAction else { return }

        hasPendingApproval = false
        isBusy = true

        updateState(
            plan: actionSummaries,
            currentStep: pendingAction.title,
            status: .executing,
            requiresApproval: false,
            message: "Executing approved action: \(pendingAction.title)"
        )

        do {
            let result = try await execute(step: pendingAction)
            interactionHistory.append(
                AgentHistoryEntry(
                    role: "tool",
                    content: result,
                    actionType: pendingAction.type.rawValue
                )
            )
            self.pendingAction = nil
            await continueAgentLoop(input: activeUserGoal ?? "", lastActionResult: result)
        } catch {
            self.pendingAction = nil
            updateState(
                plan: actionSummaries,
                currentStep: pendingAction.title,
                status: .failed,
                requiresApproval: false,
                message: "Execution failed on '\(pendingAction.title)': \(error.localizedDescription)"
            )
            isBusy = false
        }
    }

    func rejectCurrentAction() {
        let stepTitle = pendingAction?.title ?? "Action rejected"
        pendingAction = nil
        hasPendingApproval = false
        isBusy = false

        updateState(
            plan: actionSummaries,
            currentStep: stepTitle,
            status: .failed,
            requiresApproval: false,
            message: "Execution stopped because approval was not granted."
        )
    }

    private func continueAgentLoop(input: String, lastActionResult: String?) async {
        isBusy = true
        let safeInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

        updateState(
            plan: actionSummaries,
            currentStep: loopIteration == 0 ? "Reasoning" : "Continuing agent loop",
            status: .executing,
            requiresApproval: false,
            message: loopIteration == 0 ? "Calling backend agent..." : "Sending the latest execution result back to the agent."
        )

        do {
            let response = try await backendClient.sendTurn(
                conversationId: activeConversationId,
                input: safeInput,
                history: interactionHistory,
                lastActionResult: lastActionResult,
                iteration: loopIteration
            )

            activeConversationId = response.conversationId
            loopIteration = response.iteration
            interactionHistory.append(
                AgentHistoryEntry(
                    role: "assistant",
                    content: response.thought,
                    actionType: response.action.type.rawValue
                )
            )

            switch response.action.type {
            case .done:
                if !response.action.command.isEmpty {
                    actionSummaries.append("Done")
                }
                updateState(
                    plan: actionSummaries,
                    currentStep: "Completed",
                    status: .completed,
                    requiresApproval: false,
                    message: response.action.command.isEmpty ? response.thought : response.action.command
                )
                isBusy = false

            case .askUser:
                awaitingUserReply = true
                actionSummaries.append("Question: \(response.action.command)")
                updateState(
                    plan: actionSummaries,
                    currentStep: "Awaiting user input",
                    status: .pending,
                    requiresApproval: false,
                    message: response.action.command
                )
                isBusy = false

            case .shell, .applescript:
                let executableAction = AgentExecutableAction(
                    title: summarizeAction(response.action),
                    type: response.action.type,
                    command: response.action.command,
                    requiresApproval: CommandSafetyEvaluator.requiresApproval(for: response.action),
                    isDestructive: CommandSafetyEvaluator.isDestructive(response.action)
                )

                actionSummaries.append(executableAction.title)
                pendingAction = executableAction

                if executableAction.requiresApproval || executableAction.isDestructive {
                    hasPendingApproval = true
                    approvalButtonTitle = "Approve Action"
                    updateState(
                        plan: actionSummaries,
                        currentStep: executableAction.title,
                        status: .pending,
                        requiresApproval: true,
                        message: "Approval is required before executing: \(executableAction.title)"
                    )
                    isBusy = false
                } else {
                    await approveCurrentAction()
                }
            }
        } catch {
            updateState(
                plan: actionSummaries,
                currentStep: "Backend agent failed",
                status: .failed,
                requiresApproval: false,
                message: error.localizedDescription
            )
            isBusy = false
        }
    }

    private func execute(step: AgentExecutableAction) async throws -> String {
        switch step.type {
        case .shell:
            return try await ShellCommandExecutor.run(command: step.command)
        case .applescript:
            return try AppleScriptExecutor.run(script: step.command)
        case .askUser, .done:
            throw AgentExecutionError.invalidStep("Unsupported execution type: \(step.type.rawValue)")
        }
    }

    private func summarizeAction(_ action: AgentBackendAction) -> String {
        switch action.type {
        case .shell:
            return "Run shell command"
        case .applescript:
            return "Run AppleScript"
        case .askUser:
            return "Ask user"
        case .done:
            return "Done"
        }
    }

    private func mergedInputForUserReply(_ reply: String) -> String {
        let goal = activeUserGoal ?? "Unknown task"
        return """
        Original user goal: \(goal)
        User clarification: \(reply)
        """
    }

    private func resetSession() {
        activeConversationId = nil
        activeUserGoal = nil
        loopIteration = 0
        awaitingUserReply = false
        pendingAction = nil
        hasPendingApproval = false
        approvalButtonTitle = "Approve Action"
        actionSummaries.removeAll()
        interactionHistory.removeAll()
    }

    private func updateState(
        plan: [String],
        currentStep: String,
        status: AgentTaskStatus,
        requiresApproval: Bool,
        message: String
    ) {
        let publicState = AgentPublicState(
            plan: plan,
            current_step: currentStep,
            status: status.rawValue,
            requires_approval: requiresApproval,
            message: message
        )

        taskState = publicState
        renderedOutput = publicState.prettyPrintedJSONString
    }
}

struct AgentPublicState: Codable {
    let plan: [String]
    let current_step: String
    let status: String
    let requires_approval: Bool
    let message: String

    var prettyPrintedJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return """
            {
              "plan": [],
              "current_step": "Formatting failed",
              "status": "failed",
              "requires_approval": false,
              "message": "Could not render task state."
            }
            """
        }

        return string
    }
}

private struct AgentHistoryEntry: Codable {
    let role: String
    let content: String
    let actionType: String?
}

private struct AgentExecutableAction {
    let title: String
    let type: AgentActionType
    let command: String
    let requiresApproval: Bool
    let isDestructive: Bool
}

private struct AgentBackendResponse: Decodable {
    let conversationId: String
    let iteration: Int
    let thought: String
    let action: AgentBackendAction
}

private struct AgentBackendAction: Codable {
    let type: AgentActionType
    let command: String
}

private enum AgentActionType: String, Codable {
    case shell
    case applescript
    case askUser = "ask_user"
    case done
}

private enum AgentTaskStatus: String {
    case pending
    case executing
    case completed
    case failed
}

private enum AgentExecutionError: LocalizedError {
    case invalidBackendResponse(String)
    case invalidStep(String)
    case commandFailed(String)
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBackendResponse(let message),
             .invalidStep(let message),
             .commandFailed(let message),
             .appleScriptFailed(let message):
            return message
        }
    }
}

private struct AgentBackendRequest: Encodable {
    let conversationId: String?
    let input: String
    let history: [AgentHistoryEntry]
    let lastActionResult: String?
    let iteration: Int
}

private final class AgentBackendClient {
    private let session = URLSession.shared
    private let baseURL = URL(string: "http://127.0.0.1:8787")!

    func sendTurn(
        conversationId: String?,
        input: String,
        history: [AgentHistoryEntry],
        lastActionResult: String?,
        iteration: Int
    ) async throws -> AgentBackendResponse {
        let requestBody = AgentBackendRequest(
            conversationId: conversationId,
            input: input,
            history: history,
            lastActionResult: lastActionResult,
            iteration: iteration
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("agent"))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentExecutionError.invalidBackendResponse("Backend returned an invalid response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let backendError = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) {
                throw AgentExecutionError.invalidBackendResponse(backendError.error)
            }
            throw AgentExecutionError.invalidBackendResponse("Backend request failed with status \(httpResponse.statusCode).")
        }

        do {
            return try JSONDecoder().decode(AgentBackendResponse.self, from: data)
        } catch {
            throw AgentExecutionError.invalidBackendResponse("Failed to decode backend agent response.")
        }
    }
}

private struct BackendErrorResponse: Decodable {
    let error: String
}

private enum CommandSafetyEvaluator {
    private static let destructiveShellTokens = [
        "rm ", "mv ", "sudo ", "chmod ", "chown ", "defaults write",
        "diskutil erase", "installer ", "killall ", "launchctl ",
        "osascript -e 'tell application \"Finder\" to delete"
    ]

    private static let destructiveAppleScriptTokens = [
        "delete ", "move to trash", "empty trash", "quit ", "set volume",
        "do shell script \"sudo", "do shell script \"rm "
    ]

    static func requiresApproval(for action: AgentBackendAction) -> Bool {
        switch action.type {
        case .shell:
            return containsToken(action.command.lowercased(), tokens: destructiveShellTokens)
        case .applescript:
            return containsToken(action.command.lowercased(), tokens: destructiveAppleScriptTokens)
        case .askUser, .done:
            return false
        }
    }

    static func isDestructive(_ action: AgentBackendAction) -> Bool {
        requiresApproval(for: action)
    }

    private static func containsToken(_ command: String, tokens: [String]) -> Bool {
        tokens.contains { command.contains($0) }
    }
}

private enum ShellCommandExecutor {
    static func run(command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output.isEmpty ? "Command completed successfully." : output)
                } else {
                    continuation.resume(throwing: AgentExecutionError.commandFailed(errorOutput.isEmpty ? "Command exited with status \(process.terminationStatus)." : errorOutput))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AgentExecutionError.commandFailed("Failed to start command execution."))
            }
        }
    }
}

private enum AppleScriptExecutor {
    static func run(script: String) throws -> String {
        let result = try execute(script: script)
        let output = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output! : "AppleScript completed successfully."
    }

    private static func execute(script: String) throws -> NSAppleEventDescriptor {
        guard let appleScript = NSAppleScript(source: script) else {
            throw AgentExecutionError.appleScriptFailed("Failed to create AppleScript command.")
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            if shouldRetry(for: errorInfo), let appName = errorInfo["NSAppleScriptErrorAppName"] as? String {
                launchApplication(named: appName)
                Thread.sleep(forTimeInterval: 0.6)

                var retryErrorInfo: NSDictionary?
                let retryResult = appleScript.executeAndReturnError(&retryErrorInfo)
                if let retryErrorInfo {
                    throw AgentExecutionError.appleScriptFailed("AppleScript failed: \(retryErrorInfo)")
                }
                return retryResult
            }

            throw AgentExecutionError.appleScriptFailed("AppleScript failed: \(errorInfo)")
        }

        return result
    }

    private static func shouldRetry(for errorInfo: NSDictionary) -> Bool {
        let errorNumber = errorInfo["NSAppleScriptErrorNumber"] as? Int
        let errorNumberString = errorInfo["NSAppleScriptErrorNumber"] as? String
        return errorNumber == -600 || errorNumberString == "-600"
    }

    private static func launchApplication(named appName: String) {
        if let appPath = NSWorkspace.shared.fullPath(forApplication: appName) {
            let appURL = URL(fileURLWithPath: appPath)
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return
        }

        NSWorkspace.shared.launchApplication(appName)
    }
}
