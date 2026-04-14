import Foundation

/// A TGV session — corresponds to a Docker container on the remote server.
public struct Session: Identifiable, Hashable, Sendable {
    public let name: String          // Container name (used as unique ID)
    public let repo: String          // Repo URL or short name
    public let branch: String        // Git branch the session is on
    public let running: Bool         // Container Up status
    public let displayName: String?  // User-assigned label (sidecar file)
    public let insertions: Int?      // Git diff stats
    public let deletions: Int?

    public var id: String { name }

    public init(
        name: String,
        repo: String = "",
        branch: String,
        running: Bool,
        displayName: String? = nil,
        insertions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.name = name
        self.repo = repo
        self.branch = branch
        self.running = running
        self.displayName = displayName
        self.insertions = insertions
        self.deletions = deletions
    }

    /// User-facing label: "displayName (branch)" or just "branch".
    public var label: String {
        if let dn = displayName, !dn.isEmpty {
            return "\(dn) (\(branch))"
        }
        return branch
    }
}
