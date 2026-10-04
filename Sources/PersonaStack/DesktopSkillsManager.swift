import AppKit
import PersonaStackCore
import WebKit

private struct DesktopSkillWrite: Decodable {
    struct File: Decodable { let path: String; let content: String }
    let name: String
    let files: [File]
    let overwrite: Bool
    let expectedDigest: String
    enum CodingKeys: String, CodingKey { case name, files, overwrite, expectedDigest = "expected_digest" }
}

@MainActor
final class DesktopSkillsManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = DesktopSkillsManager()
    private final class Page {
        let origin: URL
        var folders: [String: URL] = [:]
        var skills: [String: URL] = [:]
        var generation = UUID()
        init(_ origin: URL) { self.origin = origin }
    }
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let files: DesktopSkillFiles
    private let pickFolder: @MainActor (String) async -> URL?
    init(files: DesktopSkillFiles = .init(), pickFolder: @escaping @MainActor (String) async -> URL? = DesktopSkillsManager.openFolderPanel) {
        self.files = files; self.pickFolder = pickFolder; super.init()
    }
    func register(_ view: WKWebView, appURL: URL) { pages.setObject(Page(appURL), forKey: view) }
    func unregister(_ view: WKWebView) { invalidate(view); pages.removeObject(forKey: view) }
    func invalidate(_ view: WKWebView) {
        guard let page = pages.object(forKey: view) else { return }
        page.folders.removeAll(); page.skills.removeAll(); page.generation = UUID()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let page = pages.object(forKey: view), ChatWindowManager.trusted(message, base: page.origin),
              let body = message.body as? [String: Any] else { replyHandler(nil, LocalSessionError.invalidRequest.rawValue); return }
        Task {
            do { replyHandler(try await apply(body, page: page), nil) }
            catch { replyHandler(nil, (error as? LocalSessionError ?? .unsafeFiles).rawValue) }
        }
    }

    func apply(_ body: [String: Any], view: WKWebView) async throws -> [String: Any] {
        guard let page = pages.object(forKey: view) else { throw LocalSessionError.invalidRequest }
        return try await apply(body, page: page)
    }

    private func apply(_ body: [String: Any], page: Page) async throws -> [String: Any] {
        let schemas: [String: Set<String>] = [
            "choose_folder": ["direction"], "list": ["folder_id"],
            "write": ["folder_id", "name", "files", "overwrite", "expected_digest"],
            "baseline": ["folder_id", "local_id", "workspace_id", "skill_id", "config_id", "revision", "config_version", "digest"]
        ]
        guard body["version"] as? String == "1", let action = body["action"] as? String, let extras = schemas[action],
              Set(body.keys) == extras.union(["version", "action"]) else { throw LocalSessionError.invalidRequest }
        if action == "choose_folder" { return try await chooseFolder(body, page: page) }
        guard let folderID = body["folder_id"] as? String, let folder = page.folders[folderID] else { throw LocalSessionError.invalidRequest }
        switch action {
        case "list": return try await list(folder, page: page)
        case "write": return try await write(body, folder: folder, page: page)
        case "baseline": return try await baseline(body, folder: folder, page: page)
        default: throw LocalSessionError.invalidRequest
        }
    }

    private func chooseFolder(_ body: [String: Any], page: Page) async throws -> [String: Any] {
        guard let direction = body["direction"] as? String, ["upload", "download"].contains(direction) else { throw LocalSessionError.invalidRequest }
        let generation = page.generation
        let selected = await pickFolder(direction)
        guard page.generation == generation else { throw LocalSessionError.staleRequest }
        guard let selected else { return ["ok": false, "cancelled": true] }
        let folder = try DesktopSkillFiles.canonicalDirectory(selected)
        if let current = page.folders.first(where: { $0.value == folder }) {
            return ["ok": true, "folder_id": current.key, "display_path": selected.path]
        }
        page.folders.removeAll(); page.skills.removeAll(); page.generation = UUID()
        let id = UUID().uuidString; page.folders[id] = folder
        return ["ok": true, "folder_id": id, "display_path": selected.path]
    }

    private static func openFolderPanel(_ direction: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = direction == "upload" ? "Choose a skill folder or a folder containing skills." : "Choose where to download workspace skills."
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        return response == .OK ? panel.url : nil
    }

    private func list(_ folder: URL, page: Page) async throws -> [String: Any] {
        let origin = page.origin, generation = page.generation, files = self.files
        let listing = try await Task.detached { try files.previewList(folder, origin: origin) }.value
        guard page.generation == generation else { throw LocalSessionError.staleRequest }
        let directories = Set(listing.skills.map(\.directory))
        page.skills = page.skills.filter { directories.contains($0.value) }
        let response = try listing.skills.map { skill -> [String: Any] in
            let id = skillHandle(skill.directory, page: page)
            var value: [String: Any] = ["local_id": id, "name": skill.name, "digest": skill.digest,
                "files": skill.files.map { ["path": $0.relativePath, "content": $0.content] }]
            if let baseline = skill.baseline { value["baseline"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) }
            return value
        }
        return ["ok": true, "skills": response, "errors": listing.errors.map { ["name": $0.name, "message": $0.message] }]
    }

    private func write(_ body: [String: Any], folder: URL, page: Page) async throws -> [String: Any] {
        let request = try JSONDecoder().decode(DesktopSkillWrite.self, from: JSONSerialization.data(withJSONObject: body))
        guard request.files.count <= 128 else { throw LocalSessionError.invalidRequest }
        let rawFiles = body["files"] as? [[String: Any]] ?? []
        guard rawFiles.allSatisfy({ Set($0.keys) == ["path", "content"] }) else { throw LocalSessionError.invalidRequest }
        let artifacts = request.files.map { LocalSessionSkillFile(relativePath: $0.path, content: $0.content) }
        let files = self.files, origin = page.origin, generation = page.generation
        let skill = try await Task.detached { try files.write(root: folder, name: request.name, files: artifacts, expectedDigest: request.expectedDigest, overwrite: request.overwrite, origin: origin) }.value
        guard page.generation == generation else { throw LocalSessionError.staleRequest }
        let id = skillHandle(skill.directory, page: page)
        return ["ok": true, "local_id": id, "digest": skill.digest]
    }

    private func skillHandle(_ directory: URL, page: Page) -> String {
        if let existing = page.skills.first(where: { $0.value == directory }) { return existing.key }
        let id = UUID().uuidString; page.skills[id] = directory
        return id
    }

    private func baseline(_ body: [String: Any], folder: URL, page: Page) async throws -> [String: Any] {
        guard let localID = body["local_id"] as? String, let directory = page.skills[localID], directory == folder || directory.deletingLastPathComponent() == folder else { throw LocalSessionError.invalidRequest }
        let baseline = try JSONDecoder().decode(DesktopSkillBaseline.self, from: JSONSerialization.data(withJSONObject: body))
        let files = self.files, origin = page.origin
        try await Task.detached { try files.saveBaseline(baseline, directory: directory, origin: origin) }.value
        return ["ok": true]
    }
}
