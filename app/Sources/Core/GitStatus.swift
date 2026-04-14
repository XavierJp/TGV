import Foundation

/// Parsed output of `git status --porcelain=v1 -b`.
public struct GitStatus: Sendable {
    public let branch: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let staged: [Entry]
    public let changed: [Entry]
    public let untracked: [Entry]

    public var isEmpty: Bool { staged.isEmpty && changed.isEmpty && untracked.isEmpty }

    /// Recent commits parsed from `git log --oneline`.
    public struct Commit: Sendable {
        public let hash: String      // short hash (7 chars)
        public let message: String
        public let author: String
        public let relDate: String   // e.g. "2 hours ago"
    }

    public struct Entry: Sendable {
        public let status: Status
        public let path: String

        public enum Status: Sendable {
            case modified
            case added
            case deleted
            case renamed
            case copied
            case untracked
        }
    }

    /// Parse `git status --porcelain=v1 -b` output.
    ///
    /// Format:
    /// ```
    /// ## main...origin/main [ahead 2, behind 1]
    ///  M src/file.swift           ← unstaged modification
    /// M  src/file.swift           ← staged modification
    /// A  src/new.swift            ← staged add
    /// ?? untracked.txt            ← untracked
    /// ```
    /// First char = index (staged) status, second = work-tree status.
    public static func parse(_ output: String) -> GitStatus {
        var branch = ""
        var upstream: String?
        var ahead = 0
        var behind = 0
        var staged: [Entry] = []
        var changed: [Entry] = []
        var untracked: [Entry] = []

        for line in output.components(separatedBy: "\n") {
            guard !line.isEmpty else { continue }

            if line.hasPrefix("## ") {
                parseBranchLine(String(line.dropFirst(3)),
                                branch: &branch, upstream: &upstream,
                                ahead: &ahead, behind: &behind)
                continue
            }

            guard line.count >= 3 else { continue }
            let chars = Array(line.unicodeScalars)
            let x = chars[0]  // index status (staged)
            let y = chars[1]  // work-tree status
            let path = String(line.dropFirst(3))

            if x == "?" && y == "?" {
                untracked.append(Entry(status: .untracked, path: path))
            } else {
                // Staged entry (index column has a status letter)
                if x != " " && x != "?" {
                    staged.append(Entry(status: charToStatus(x), path: path))
                }
                // Unstaged entry (work-tree column has a status letter)
                if y != " " && y != "?" {
                    changed.append(Entry(status: charToStatus(y), path: path))
                }
            }
        }

        return GitStatus(branch: branch, upstream: upstream,
                         ahead: ahead, behind: behind,
                         staged: staged, changed: changed,
                         untracked: untracked)
    }

    /// Parse `git log --format='%h|%s|%an|%ar' -20` output into Commit structs.
    public static func parseLog(_ output: String) -> [Commit] {
        var commits: [Commit] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count >= 4 else { continue }
            commits.append(Commit(
                hash: parts[0],
                message: parts[1],
                author: parts[2],
                relDate: parts[3]
            ))
        }
        return commits
    }

    private static func charToStatus(_ c: Unicode.Scalar) -> Entry.Status {
        switch c {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        default:  return .modified
        }
    }

    /// Parse branch line: "main...origin/main [ahead 2, behind 1]"
    private static func parseBranchLine(
        _ line: String,
        branch: inout String, upstream: inout String?,
        ahead: inout Int, behind: inout Int
    ) {
        var rest = line

        // Extract [ahead N, behind M] if present
        if let bracketStart = rest.range(of: " [") {
            let bracket = String(rest[bracketStart.upperBound...])
                .replacingOccurrences(of: "]", with: "")
            for part in bracket.components(separatedBy: ", ") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ahead ") {
                    ahead = Int(trimmed.dropFirst("ahead ".count)) ?? 0
                } else if trimmed.hasPrefix("behind ") {
                    behind = Int(trimmed.dropFirst("behind ".count)) ?? 0
                }
            }
            rest = String(rest[..<bracketStart.lowerBound])
        }

        // Split "main...origin/main" or just "main"
        let parts = rest.components(separatedBy: "...")
        branch = parts[0]
        if parts.count > 1 && !parts[1].isEmpty {
            upstream = parts[1]
        }
    }
}
