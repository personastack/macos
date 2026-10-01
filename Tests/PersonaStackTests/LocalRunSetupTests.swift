import CryptoKit
import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

struct LocalRunSetupTests {
    @Test(arguments: [[0, 0], [1, 0], [0, 1]])
    func startsRuntimeAndChecksReadiness(statuses: [Int32]) async throws {
        let fixture = RuntimeStartFixture(statuses: statuses)
        let runtime = LocalRunContainer(command: { try await fixture.run($0) })
        if statuses == [0, 0] { try await runtime.startService() }
        else { await #expect(throws: LocalRunError.runtimeUnavailable) { try await runtime.startService() } }
        let expected = statuses[0] == 0 ? [["system", "start", "--enable-kernel-install"], ["system", "status"]]
            : [["system", "start", "--enable-kernel-install"]]
        #expect(await fixture.commands == expected)
    }

    @Test func verifiesInstallerDigestBeforeOpeningPackage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("local-run-installer-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let content = Data("fixture package".utf8)
        try content.write(to: file)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        try LocalRunSetupManager.verifyInstaller(at: file, expectedDigest: digest)
        #expect(throws: LocalRunError.setupFailed) { try LocalRunSetupManager.verifyInstaller(at: file) }
        try Data("tampered package".utf8).write(to: file)
        #expect(throws: LocalRunError.setupFailed) { try LocalRunSetupManager.verifyInstaller(at: file, expectedDigest: digest) }
    }
}

private actor RuntimeStartFixture {
    let statuses: [Int32]
    var commands: [[String]] = []
    init(statuses: [Int32]) { self.statuses = statuses }
    func run(_ arguments: [String]) throws -> LocalRunCommandResult {
        let expected = commands.isEmpty ? ["system", "start", "--enable-kernel-install"] : ["system", "status"]
        guard commands.count < statuses.count, arguments == expected else { throw LocalRunError.invalidFrame }
        let status = statuses[commands.count]
        commands.append(arguments)
        return LocalRunCommandResult(status: status)
    }
}
