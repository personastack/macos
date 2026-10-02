import Foundation

public enum DesktopDownloadDestination {
    /// WebKit requires a nonexistent file. Keep web-provided names inside the
    /// chosen directory and preserve an existing download with the same name.
    public static func choose(suggestedFilename: String, directory: URL,
                              fileManager: FileManager = .default) -> URL? {
        guard directory.isFileURL else { return nil }
        var name = (suggestedFilename as NSString).lastPathComponent
        if name.isEmpty || [".", "..", "/"].contains(name)
            || name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            name = "download"
        }
        let pathExtension = (name as NSString).pathExtension
        let extensionSuffix = !pathExtension.isEmpty && pathExtension.utf8.count <= 64 ? "." + pathExtension : ""
        let stem = extensionSuffix.isEmpty ? name : (name as NSString).deletingPathExtension
        for number in 0..<10_000 {
            let suffix = number == 0 ? "" : " (\(number))"
            var boundedStem = stem
            while (boundedStem + suffix + extensionSuffix).utf8.count > 255 { boundedStem.removeLast() }
            let candidate = directory.appendingPathComponent(boundedStem + suffix + extensionSuffix)
            let exists = fileManager.fileExists(atPath: candidate.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil
            if !exists { return candidate }
        }
        return nil
    }
}
