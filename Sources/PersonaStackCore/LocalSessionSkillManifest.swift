import Foundation
import Yams

public enum LocalSessionSkillManifest {
    /// Called only after verifying the original artifact digest. Preserve all other
    /// YAML metadata and body/assets while assigning a collision-resistant skill name.
    public static func renamed(_ content: String, name: String) throws -> String {
        do {
            guard name.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  content.utf8.count <= 512 * 1024 else { throw LocalSessionError.invalidBundle }
            let lines = content.components(separatedBy: "\n")
            guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
                  let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }),
                  var node = try Yams.compose(yaml: lines[1..<end].joined(separator: "\n")),
                  let mapping = node.mapping,
                  let description = node["description"]?.string, !description.isEmpty else { throw LocalSessionError.invalidBundle }
            var keys = Set<String>()
            for pair in mapping {
                guard let key = pair.key.string, keys.insert(key).inserted else { throw LocalSessionError.invalidBundle }
            }
            node["name"] = Node(name)
            let yaml = try Yams.serialize(node: node)
            return "---\n" + yaml + "---\n" + lines.dropFirst(end + 1).joined(separator: "\n")
        } catch { throw LocalSessionError.invalidBundle }
    }
}
