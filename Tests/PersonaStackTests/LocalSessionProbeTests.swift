import Foundation
import Testing
@testable import PersonaStackCore

struct LocalSessionProbeTests {
    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func profileDiscoveryUsesExistingNamedDirectoriesAndPreservesSymlink(_ harness: LocalSessionHarness) throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("profile-choice-" + UUID().uuidString)
        defer { try? manager.removeItem(at: home) }
        let name = harness == .codex ? "codex" : "claude"
        let personal = home.appendingPathComponent(".ai/eg/" + name)
        let work = home.appendingPathComponent(".ai/epic/" + name)
        try manager.createDirectory(at: personal, withIntermediateDirectories: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("." + name)
        try manager.createSymbolicLink(at: link, withDestinationURL: personal)
        let current = LocalSessionHarnessProbe(executable: URL(fileURLWithPath: "/usr/bin/true"), home: home, profile: link, shell: URL(fileURLWithPath: "/bin/zsh"), environment: ["PATH": "/usr/bin:/bin", "KEEP": "fixture"])
        let profiles = LocalSessionProbe.profiles(harness, current: current)
        #expect(profiles.map(\.label) == ["Personal (current)", "Work"])
        #expect(profiles.map { $0.installation.profile.path } == [personal.path, work.path])
        #expect(profiles.map { $0.installation.environment[name == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] } == [personal.path, work.path])
        #expect(profiles.allSatisfy { $0.installation.environment["KEEP"] == "fixture" && $0.installation.executable == current.executable })
        #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == personal.path)
        let missing = LocalSessionHarnessProbe(executable: current.executable, home: home.appendingPathComponent("missing"), profile: home.appendingPathComponent("custom"), shell: current.shell)
        #expect(LocalSessionProbe.profiles(harness, current: missing).count == 1)
        #expect(!manager.fileExists(atPath: missing.home.path))
    }

    @Test(arguments: ["/bin/zsh", "/bin/tcsh"])
    func localSessionProbeLoadsInteractiveLoginProfile(shell: String) throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("personastack-shell-" + UUID().uuidString)
        try manager.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: false)
        let cli = bin.appendingPathComponent("codex")
        try Data("#!/bin/sh\ncase \"$1:$2:$3\" in --version::) printf 'codex-cli 0.154.0\\n';; --help::) printf '%s\\n' 'plugin';; plugin:--help:) printf '%s\\n' 'add';; mcp:--help:) printf '%s\n' 'add get list login logout remove';; plugin:marketplace:--help) printf '%s\\n' 'add list';; *) exit 1;; esac\n".utf8).write(to: cli)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try Data("export PATH=\"$HOME/bin:/usr/bin:/bin\"\nexport CODEX_HOME=\"$HOME/custom-codex\"\nexport CLAUDE_CONFIG_DIR=\"$HOME/custom-claude\"\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        try Data("setenv PATH \"$HOME/bin:/usr/bin:/bin\"\nsetenv CODEX_HOME \"$HOME/custom-codex\"\nsetenv CLAUDE_CONFIG_DIR \"$HOME/custom-claude\"\n".utf8).write(to: home.appendingPathComponent(".tcshrc"))
        let result = try LocalSessionProbe.inspect(.codex, shell: URL(fileURLWithPath: shell), environment: ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin"])
        #expect(result.executable == cli)
        #expect(result.profile == home.appendingPathComponent("custom-codex"))
        #expect(result.home.path == home.path)
    }

    @Test func localSessionProbeRequiresKnownBaselineAndAdditiveFlags() throws {
        try LocalSessionProbe.validateCapabilities(.codex, version: "codex-cli 0.154.0", help: "plugin", pluginHelp: "add", marketplaceHelp: "add list")
        try LocalSessionProbe.validateCapabilities(.claudeCode, version: "2.1.152 (Claude Code)", help: "plugin", pluginHelp: "install", marketplaceHelp: "add list")
        for version in ["codex-cli 0.153.0", "invalid"] {
            #expect(throws: LocalSessionError.outdatedHarness) { try LocalSessionProbe.validateCapabilities(.codex, version: version, help: "plugin", pluginHelp: "add", marketplaceHelp: "add list") }
        }
        #expect(throws: LocalSessionError.outdatedHarness) { try LocalSessionProbe.validateCapabilities(.claudeCode, version: "2.2.0", help: "plugin", pluginHelp: "install", marketplaceHelp: "") }
    }

    @Test func localSessionProbeSeparatesShellNoiseAndProfilePaths() throws {
        let fields = try LocalSessionProbe.parseEnvironment("shell greeting\nmarker\0/opt/homebrew/bin/codex\n\0/Users/Test Person\0/Users/Test Person/.ai/eg/codex\0/Users/Test Person/.ai/eg/claude\0/usr/bin:/opt/homebrew/bin\0", marker: "marker")
        #expect(fields.count == 5)
        #expect(fields[0] == "/opt/homebrew/bin/codex")
        #expect(fields[2] == "/Users/Test Person/.ai/eg/codex")
        #expect(throws: LocalSessionError.missingHarness) { try LocalSessionProbe.parseEnvironment("alias codex=something", marker: "marker") }
        #expect(throws: LocalSessionError.missingHarness) { try LocalSessionProbe.parseEnvironment("\nmarker\0relative\n\0/home\0/home/codex\0/home/claude\0/bin\0", marker: "marker") }
    }
}
