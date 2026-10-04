import Darwin
import Foundation
import PersonaStackCore

private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

private func run() async throws {
    guard let connectionID = argument("--connection") else { throw LocalSessionError.invalidRequest }
    let credential = try HarnessActivityKeychain().read(connectionID)
    guard credential.routingEnabled else { return }
    let store = HarnessHookState()
    if let sessionID = argument("--renew"), let runID = argument("--run") {
        var renewal = HarnessActivityRenewal(leaseStartedAt: Date())
        while true {
            try await Task.sleep(for: .seconds(15))
            guard try await renewal.step(store: store, connectionID: connectionID, sessionID: sessionID, runID: runID, report: { state in
                try await HarnessActivityReporter.report(credential, sessionID: sessionID, runID: runID, state: state)
            }) else { return }
        }
    }
    guard let event = argument("--event") else { throw LocalSessionError.invalidRequest }
    let input = try HarnessHookInput.decode(FileHandle.standardInput.readData(ofLength: 512 * 1024 + 1))
    let runID = try await HarnessHookDispatcher.dispatch(credential, event: event, input: input, store: store) { runID, state in
        try await HarnessActivityReporter.report(credential, sessionID: input.sessionID, runID: runID, state: state)
    }
    if let runID {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--connection", connectionID, "--renew", input.sessionID, "--run", runID]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

// A failed report must never block or fail the user's agent turn. No payload or credential is logged.
do { try await run() } catch { }
