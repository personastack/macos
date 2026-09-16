import Foundation
import PersonaStackCore

do {
    guard CommandLine.arguments.count == 2, let id = UUID(uuidString: CommandLine.arguments[1]) else {
        throw LocalSessionError.invalidRequest
    }
    let invocation = try LocalSessionHelper.invocation(sessionID: id, environment: ProcessInfo.processInfo.environment)
    try LocalSessionHelper.execute(invocation)
} catch {
    // Never print raw decoder/process errors, paths, bundle values, or credentials.
    let message = (error as? LocalSessionError ?? .unsafeFiles).rawValue
    FileHandle.standardError.write(Data(("PersonaStack: " + message + "\n").utf8))
    exit(1)
}
