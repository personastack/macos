import Foundation

/// Shared shell quoting is used only to load the user's login shell during CLI discovery.
public enum LocalSessionLauncher {
    /// A leading '-' argv[0] requests login initialization across macOS shells.
    /// Unlike '-l', this also works with tcsh when a command is supplied.
    static func loginArguments(shell: URL, command: String) -> [String] {
        ["-c", "exec -a \"-${1##*/}\" \"$@\"", "personastack", shell.path, "-i", "-c", command]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
