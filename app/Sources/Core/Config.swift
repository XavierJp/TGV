import Foundation

/// Config loaded from ~/.tgv/config.toml (created by `tgv init`).
public struct TGVConfig: Sendable {
    public let host: String
    public let user: String
    public let repoURL: String
    public let dockerImage: String
    public let dockerNetwork: String
    public let defaultBranch: String
    public let gitName: String
    public let gitEmail: String

    public var sshTarget: String { "\(user)@\(host)" }

    public static func load() -> TGVConfig? {
        let path = NSString(string: "~/.tgv/config.toml").expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return parse(contents)
    }

    /// Minimal TOML extractor — matches `key = "value"` lines.
    /// Doesn't understand sections; the TGV config has unique keys across sections
    /// (host, user, image, network, url, default_branch, name, email) so this is fine.
    static func parse(_ contents: String) -> TGVConfig? {
        func get(_ key: String) -> String? {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let pattern = "^\\s*\(escapedKey)\\s*=\\s*\"([^\"]*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
                return nil
            }
            let range = NSRange(contents.startIndex..., in: contents)
            guard let match = regex.firstMatch(in: contents, range: range),
                  let valueRange = Range(match.range(at: 1), in: contents) else {
                return nil
            }
            return String(contents[valueRange])
        }

        guard let host = get("host"), let user = get("user") else { return nil }

        return TGVConfig(
            host: host,
            user: user,
            repoURL: get("url") ?? "",
            dockerImage: get("image") ?? "tgv-session:latest",
            dockerNetwork: get("network") ?? "tgv-net",
            defaultBranch: get("default_branch") ?? "main",
            gitName: get("name") ?? "",
            gitEmail: get("email") ?? ""
        )
    }
}
