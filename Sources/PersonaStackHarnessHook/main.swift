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
    guard let event = argument("--event"), ["UserPromptSubmit", "Stop", "StopFailure", "Interrupt", "SessionEnd"].contains(event) else { throw LocalSessionError.invalidRequest }
    let input = try HarnessHookInput.decode(FileHandle.standardInput.readData(ofLength: 512 * 1024 + 1))
    let active = try store.lock(connectionID: connectionID, sessionID: input.sessionID)
    defer { active.unlock() }
    let previous = try active.read()
    if event == "UserPromptSubmit" {
        if let previous, let turnID = input.turnID, previous.turnID == turnID { return }
        let turn = HarnessHookTurn(runID: UUID().uuidString.lowercased(), turnID: input.turnID, ownerPID: getppid())
        try active.write(turn)
        do {
            guard try await HarnessActivityReporter.report(credential, sessionID: input.sessionID, runID: turn.runID, state: "start") else { try active.clear(); return }
        } catch { try active.clear(); throw error }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--connection", connectionID, "--renew", input.sessionID, "--run", turn.runID]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    } else if let previous {
        if let turnID = input.turnID, previous.turnID != nil, previous.turnID != turnID { return }
        try active.clear()
        _ = try await HarnessActivityReporter.report(credential, sessionID: input.sessionID, runID: previous.runID, state: "stop")
    }
}

// A failed report must never block or fail the user's agent turn. No payload or credential is logged.
do { try await run() } catch { }
