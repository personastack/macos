import Foundation
import Testing
@testable import PersonaStackCore

struct LocalSessionBundleTests {
    let appURL = URL(string: "https://my.personastack.ai/user/personas")!
    let now = Date(timeIntervalSince1970: 1_789_516_800) // 2026-09-16 UTC

    func fixture() -> [String: Any] {
        ["persona_id": "persona-a", "persona_name": "Local persona", "workspace_id": "ws_11111111111111111111111111111111",
         "harness": "codex", "issued_at": "2026-09-16T00:00:00Z", "expires_at": "2027-09-16T00:00:00Z",
         "mcp_url": "https://mcp.personastack.ai/v1/mcp", "bearer_token": String(repeating: "a", count: 64),
         "persona_prompt": "Help with the task.", "skills": []]
    }

    @Test func localSessionDecodesGoProducerFixture() throws {
        // Serialized by apicontract.LocalSessionResponse at API revision edbd9c147.
        // The repeated "a" bearer is deliberately inert fixture data.
        let url = try #require(Bundle.module.url(forResource: "local-session", withExtension: "json"))
        let bundle = try LocalSessionBundle.decode(Data(contentsOf: url), appURL: appURL, now: now)
        #expect(bundle.personaID == "persona-a")
        #expect(bundle.skills.count == 1)
        #expect(bundle.skills[0].skillID == "skill-fixture")
        #expect(bundle.skills[0].digest == LocalSessionSkill.digest(bundle.skills[0].files))
        #expect(bundle.skills[0].files[0].relativePath == "SKILL.md")
    }

    @Test func localSessionProducerDTOAndFixedLifetime() throws {
        let data = try JSONSerialization.data(withJSONObject: fixture())
        let bundle = try LocalSessionBundle.decode(data, appURL: appURL, now: now)
        #expect(bundle.harness == .codex)
        #expect(bundle.personaID == "persona-a")
        #expect(bundle.skills.isEmpty)
        try bundle.validate(appURL: appURL, now: now.addingTimeInterval(364 * 24 * 60 * 60))
        #expect(throws: LocalSessionError.invalidBundle) {
            try bundle.validate(appURL: appURL, now: now.addingTimeInterval(LocalSessionBundle.lifetime))
        }
        let roundtrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)) as? [String: Any]
        #expect(Set(roundtrip?.keys.map { $0 } ?? []) == Set(fixture().keys))
    }

    @Test func localSessionRejectsUnknownFieldsAndDestinations() throws {
        for (key, value) in [("command", "touch file"), ("harness", "other"), ("persona_id", "../persona"),
                             ("workspace_id", "foreign"), ("bearer_token", "secret"),
                             ("mcp_url", "https://foreign.example/v1/mcp"), ("expires_at", "2027-10-01T00:00:00Z")] {
            var body = fixture()
            body[key] = value
            let data = try JSONSerialization.data(withJSONObject: body)
            #expect(throws: LocalSessionError.invalidBundle) { try LocalSessionBundle.decode(data, appURL: appURL, now: now) }
        }
        var body = fixture()
        body["persona_prompt"] = String(repeating: "x", count: 128 * 1024 + 1)
        #expect(throws: LocalSessionError.invalidBundle) {
            try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: body), appURL: appURL, now: now)
        }
        #expect(!LocalSessionBundle.permitsMCP("http://mcp.personastack.lan/v1/mcp", appURL: appURL))
        #expect(LocalSessionBundle.permitsMCP("http://mcp.personastack.lan/v1/mcp", appURL: URL(string: "https://personastack.ericgreer.info/user/personas")!))
        #expect(!LocalSessionBundle.permitsMCP("https://mcp.personastack.ai/v1/mcp", appURL: URL(string: "https://my.personastack.ai:444")!))
    }

    @Test func localSessionSkillIntegrityAndSafePaths() throws {
        let files = [LocalSessionSkillFile(relativePath: "SKILL.md", content: "---\r\nname: example\r\ndescription: Example.\r\nlicense: MIT\r\n---\r\nInstructions.\r\n"),
                     LocalSessionSkillFile(relativePath: "references/Usage Guide.md", content: "Original bytes.\r\n")]
        let skill = LocalSessionSkill(skillID: "skill-a", slug: "example", digest: LocalSessionSkill.digest(files), files: files)
        try skill.validate()
        #expect(skill.files[0].content.contains("\r\n"))
        for path in ["../outside", "/absolute", "a/../b", "a//b", "a\\b", "a\0b", "a/", "."] {
            #expect(!LocalSessionSkill.safePath(path))
        }
        for extra in [LocalSessionSkillFile(relativePath: "skill.md", content: "collision"),
                      LocalSessionSkillFile(relativePath: "SKILL.md/child", content: "file-directory collision")] {
            let invalid = files + [extra]
            #expect(throws: LocalSessionError.invalidBundle) {
                try LocalSessionSkill(skillID: "skill-a", slug: "example", digest: LocalSessionSkill.digest(invalid), files: invalid).validate()
            }
        }
        #expect(throws: LocalSessionError.invalidBundle) {
            try LocalSessionSkill(skillID: "skill-a", slug: "example", digest: "sha256:wrong", files: files).validate()
        }
    }

    @Test func localSessionNamespacingRetainsPublicSkillMetadata() throws {
        let source = "---\r\nname: example\r\ndescription: Example.\r\nlicense: MIT\r\nmetadata:\r\n  author: upstream\r\nallowed-tools: Read\r\n---\r\nBody\r\nwith original endings.\r\n"
        let renamed = try LocalSessionSkillManifest.renamed(source, name: "ps-unique")
        #expect(renamed.contains("name: ps-unique"))
        #expect(renamed.contains("license: MIT"))
        #expect(renamed.contains("author: upstream"))
        #expect(renamed.contains("allowed-tools: Read"))
        #expect(renamed.hasSuffix("Body\r\nwith original endings.\r\n"))
        #expect(throws: LocalSessionError.invalidBundle) {
            try LocalSessionSkillManifest.renamed("---\nname: one\nname: two\ndescription: Example.\n---\n", name: "ps-unique")
        }
    }
}
