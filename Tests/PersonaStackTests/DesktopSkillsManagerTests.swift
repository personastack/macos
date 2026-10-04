import AppKit
import Foundation
import Testing
import WebKit
@testable import PersonaStack
@testable import PersonaStackCore

@MainActor
struct DesktopSkillsManagerTests {
    private let origin = URL(string: "https://my.personastack.ai")!
    private let workspace = "ws_11111111111111111111111111111111"
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("skill-manager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func request(_ action: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        fields.merging(["version": "1", "action": action]) { _, new in new }
    }
    private func skills(_ manager: DesktopSkillsManager, view: WKWebView, folder: String) async throws -> [[String: Any]] {
        try #require(try await manager.apply(request("list", ["folder_id": folder]), view: view)["skills"] as? [[String: Any]])
    }
    private func save(_ baseline: DesktopSkillBaseline, localID: String, folder: String, manager: DesktopSkillsManager, view: WKWebView) async throws {
        var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
        body["local_id"] = localID; body["folder_id"] = folder
        #expect(try await manager.apply(request("baseline", body), view: view)["ok"] as? Bool == true)
    }

    @Test func previewRefreshMultiUploadReadbackAndFailedRetryUseRealManagerHandles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        for name in ["alpha", "beta", "gamma"] {
            _ = try files.write(root: root, name: name, files: [.init(relativePath: "SKILL.md", content: "Skill \(name)"), .init(relativePath: "asset.txt", content: "Asset \(name)")], expectedDigest: "", overwrite: false, origin: origin)
        }
        let manager = DesktopSkillsManager(files: files, pickFolder: { _ in root })
        let view = WKWebView(); manager.register(view, appURL: origin)
        let folder = try #require(try await manager.apply(request("choose_folder", ["direction": "upload"]), view: view)["folder_id"] as? String)
        let preview = try await skills(manager, view: view, folder: folder)
        var uploaded: [String: DesktopSkillBaseline] = [:]
        var attempts: [String: Int] = [:]
        var finished = Set<String>()
        // The hosted controller refreshes before each upload. One API failure is retried.
        for pass in 0..<2 {
            for item in preview {
                let id = try #require(item["local_id"] as? String)
                guard !finished.contains(id) else { continue }
                let refreshed = try await skills(manager, view: view, folder: folder)
                let current = try #require(refreshed.first { $0["local_id"] as? String == id })
                #expect(current["digest"] as? String == item["digest"] as? String)
                let name = try #require(current["name"] as? String)
                attempts[name, default: 0] += 1
                if pass == 0 && name == "beta" { continue }
                // Strict fake API commits and returns separate catalog/configuration identities.
                let digest = try #require(current["digest"] as? String)
                #expect(uploaded[name] == nil)
                uploaded[name] = DesktopSkillBaseline(workspaceID: workspace, skillID: "catalog-\(name)", configID: "config-\(name)", revision: 3, configVersion: 4, digest: digest)
                let readback = try #require(uploaded[name])
                try await save(readback, localID: id, folder: folder, manager: manager, view: view)
                finished.insert(id)
            }
        }
        #expect(finished.count == 3)
        #expect(attempts == ["alpha": 1, "beta": 2, "gamma": 1])
        let readback = try await skills(manager, view: view, folder: folder)
        for item in readback {
            let name = try #require(item["name"] as? String)
            let encoded = try JSONSerialization.data(withJSONObject: try #require(item["baseline"] as? [String: Any]))
            #expect(try JSONDecoder().decode(DesktopSkillBaseline.self, from: encoded) == uploaded[name])
            #expect(preview.contains { $0["local_id"] as? String == item["local_id"] as? String })
        }
    }

    @Test func vanishedSkillsFolderChangesAndNavigationInvalidateOldHandles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        let local = try files.write(root: root, name: "review", files: [.init(relativePath: "SKILL.md", content: "Review")], expectedDigest: "", overwrite: false, origin: origin)
        var selected = root
        let manager = DesktopSkillsManager(files: files, pickFolder: { _ in selected })
        let view = WKWebView(); manager.register(view, appURL: origin)
        let folder = try #require(try await manager.apply(request("choose_folder", ["direction": "upload"]), view: view)["folder_id"] as? String)
        let initial = try await skills(manager, view: view, folder: folder)
        let id = try #require(initial.first?["local_id"] as? String)
        let baseline = DesktopSkillBaseline(workspaceID: workspace, skillID: "catalog", configID: "config", revision: 1, configVersion: 1, digest: local.digest)
        try FileManager.default.moveItem(at: local.directory.appendingPathComponent("SKILL.md"), to: local.directory.appendingPathComponent("removed.txt"))
        #expect(try await skills(manager, view: view, folder: folder).isEmpty)
        await #expect(throws: LocalSessionError.invalidRequest) { try await save(baseline, localID: id, folder: folder, manager: manager, view: view) }
        try FileManager.default.moveItem(at: local.directory.appendingPathComponent("removed.txt"), to: local.directory.appendingPathComponent("SKILL.md"))
        let restored = try await skills(manager, view: view, folder: folder)
        let restoredID = try #require(restored.first?["local_id"] as? String)
        #expect(restoredID != id)
        selected = local.directory
        let changed = try #require(try await manager.apply(request("choose_folder", ["direction": "upload"]), view: view)["folder_id"] as? String)
        #expect(changed != folder)
        await #expect(throws: LocalSessionError.invalidRequest) { _ = try await skills(manager, view: view, folder: folder) }
        await #expect(throws: LocalSessionError.invalidRequest) { try await save(baseline, localID: restoredID, folder: changed, manager: manager, view: view) }
        let current = try await skills(manager, view: view, folder: changed)
        let currentID = try #require(current.first?["local_id"] as? String)
        manager.invalidate(view)
        await #expect(throws: LocalSessionError.invalidRequest) { try await save(baseline, localID: currentID, folder: changed, manager: manager, view: view) }
    }

    @Test func writeAndRefreshRetainSameHandleAndBaselineRejectsChangedContent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopSkillFiles(metadataRoot: root.appendingPathComponent("metadata"))
        let manager = DesktopSkillsManager(files: files, pickFolder: { _ in root })
        let view = WKWebView(); manager.register(view, appURL: origin)
        let folder = try #require(try await manager.apply(request("choose_folder", ["direction": "download"]), view: view)["folder_id"] as? String)
        let written = try await manager.apply(request("write", ["folder_id": folder, "name": "review", "files": [["path": "SKILL.md", "content": "Review"]], "expected_digest": "", "overwrite": false]), view: view)
        let id = try #require(written["local_id"] as? String)
        let digest = try #require(written["digest"] as? String)
        #expect(try await skills(manager, view: view, folder: folder).first?["local_id"] as? String == id)
        let baseline = DesktopSkillBaseline(workspaceID: workspace, skillID: "catalog", configID: "config", revision: 1, configVersion: 1, digest: digest)
        try Data("Local change".utf8).write(to: root.appendingPathComponent("review/SKILL.md"))
        await #expect(throws: LocalSessionError.staleRequest) { try await save(baseline, localID: id, folder: folder, manager: manager, view: view) }
        #expect(try files.read(root.appendingPathComponent("review"), origin: origin).baseline == nil)
    }
}
