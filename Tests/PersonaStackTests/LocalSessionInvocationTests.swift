import Foundation
import Testing
@testable import PersonaStackCore

struct LocalSessionInvocationTests {
    @Test func localSessionHelperRejectsDisappearedExecutable() throws {
        let invocation = LocalSessionInvocation(executable: URL(fileURLWithPath: "/tmp/absent-personastack-cli-" + UUID().uuidString),
                                               workingDirectory: URL(fileURLWithPath: "/"), arguments: [], environment: [:])
        // Rejection occurs before chdir or exec. No process or global-directory mutation.
        #expect(throws: LocalSessionError.missingHarness) { try LocalSessionHelper.execute(invocation) }
    }

    private func bundle(_ harness: LocalSessionHarness) throws -> LocalSessionBundle {
        let fixtures = LocalSessionBundleTests()
        var value = fixtures.fixture()
        value["harness"] = harness.rawValue
        return try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: value), appURL: fixtures.appURL, now: fixtures.now)
    }

    @Test func localSessionAdditiveArgumentsAndChildOnlyCredential() throws {
        let home = URL(fileURLWithPath: "/tmp/Test user's home $x ü")
        let session = home.appendingPathComponent("Library/Application Support/PersonaStack/LocalSessions/a")
        let inherited = ["HOME": home.path, "CODEX_HOME": "/tmp/profile/codex", "CLAUDE_CONFIG_DIR": "/tmp/profile/claude", "PATH": "/usr/bin", "UNCHANGED": "value"]
        for harness in LocalSessionHarness.allCases {
            let value = try bundle(harness)
            let firstID = UUID()
            let first = try LocalSessionInvocation.make(bundle: value, sessionID: firstID, executable: home.appendingPathComponent("bin/cli"), home: home, sessionDirectory: session, inheritedEnvironment: inherited)
            #expect(first.workingDirectory == home)
            #expect(!first.arguments.joined().contains(value.bearerToken))
            for (key, value) in inherited { #expect(first.environment[key] == value) }
            #expect(inherited.keys.allSatisfy { !$0.hasPrefix("PERSONASTACK_LOCAL_TOKEN_") })
            if harness == .codex {
                #expect(first.arguments.prefix(2) == ["--cd", home.path])
                #expect(first.environment.values.contains(value.bearerToken))
                #expect(first.arguments.contains(where: { $0.contains(LocalSessionInvocation.serverName(firstID) + ".url=") }))
                #expect(first.arguments.contains("mcp_servers.\(LocalSessionInvocation.serverName(firstID)).url=\"https://mcp.personastack.ai/v1/mcp\""))
                let second = try LocalSessionInvocation.make(bundle: value, sessionID: UUID(), executable: first.executable, home: home, sessionDirectory: session, inheritedEnvironment: inherited)
                #expect(first.arguments != second.arguments)
                #expect(Set(first.environment.keys) != Set(second.environment.keys))
            } else {
                #expect(first.environment == inherited)
                #expect(first.arguments == ["--plugin-dir", session.appendingPathComponent("plugin").path,
                                            "--mcp-config", session.appendingPathComponent("mcp.json").path,
                                            "--append-system-prompt-file", session.appendingPathComponent("persona.md").path])
            }
            #expect(!first.arguments.contains("--strict-mcp-config"))
            #expect(!first.arguments.contains("--bare"))
            #expect(!first.arguments.joined().contains("developer_instructions"))
        }
    }

    @Test func localSessionLauncherContainsOnlyNativeHandoff() throws {
        let id = UUID()
        let source = try LocalSessionLauncher.command(helper: URL(fileURLWithPath: "/Applications/Persona's $ App.app/Contents/MacOS/PersonaStackLocalSession"), sessionID: id, loginShell: URL(fileURLWithPath: "/bin/zsh"))
        #expect(source.hasPrefix("#!/bin/sh\nexec /bin/bash "))
        #expect(source.contains("'/bin/zsh' '-i' '-c'"))
        #expect(source.contains(id.uuidString))
        #expect(!source.contains(try bundle(.codex).bearerToken))
        #expect(source.components(separatedBy: "\n").count == 3)
        #expect(throws: LocalSessionError.invalidRequest) {
            try LocalSessionLauncher.command(helper: URL(fileURLWithPath: "/tmp/line\nbreak"), sessionID: id, loginShell: URL(fileURLWithPath: "/bin/zsh"))
        }
    }
}
