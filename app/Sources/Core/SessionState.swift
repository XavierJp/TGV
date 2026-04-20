import Foundation
import Combine

public enum SessionStatus: Sendable, Equatable {
    case creating   // spawn is in-flight, container not yet reported by server
    case running    // container Up on server
    case stopped    // container exists on server but not Up
    case deleting   // kill is in-flight, server has not yet removed it
}

/// Per-session client-side state. Reference type so views can observe mutations
/// via Combine. All mutation happens on the main actor.
@MainActor
public final class SessionState: ObservableObject, @MainActor Identifiable {
    public let name: String
    @Published public var repo: String
    @Published public var branch: String
    @Published public var displayName: String?
    @Published public var status: SessionStatus
    @Published public var insertions: Int?
    @Published public var deletions: Int?

    // Cached per-kind data + refresh timestamps. `@Published` on the timestamp is
    // what drives the stale indicator.
    @Published public var gitStatus: GitStatus?
    @Published public var commits: [GitStatus.Commit] = []
    @Published public var gitRefreshedAt: Date?

    @Published public var filePaths: [String] = []
    @Published public var fileTree: [FileNode] = []
    @Published public var filesRefreshedAt: Date?

    // Lifecycle log — surfaced in the splash for CREATING / DELETING
    @Published public var statusLog: [String] = []

    public var id: String { name }

    public init(
        name: String,
        repo: String = "",
        branch: String,
        displayName: String? = nil,
        status: SessionStatus
    ) {
        self.name = name
        self.repo = repo
        self.branch = branch
        self.displayName = displayName
        self.status = status
    }

    /// User-facing label: "displayName (branch)" or just "branch".
    public var label: String {
        if let dn = displayName, !dn.isEmpty {
            return "\(dn) (\(branch))"
        }
        return branch
    }

    /// Staleness threshold — views should treat cached data as stale when true.
    public static let staleThreshold: TimeInterval = 2.0

    public var isGitStale: Bool {
        guard let t = gitRefreshedAt else { return true }
        return Date().timeIntervalSince(t) > Self.staleThreshold
    }

    public var isFilesStale: Bool {
        guard let t = filesRefreshedAt else { return true }
        return Date().timeIntervalSince(t) > Self.staleThreshold
    }

    /// Merge a freshly-listed Session DTO into the live state. Keeps status
    /// transitions explicit so spawn/kill flows aren't clobbered by list polls.
    public func applyListed(_ session: Session) {
        if repo != session.repo { repo = session.repo }
        if branch != session.branch { branch = session.branch }
        if displayName != session.displayName { displayName = session.displayName }
        if insertions != session.insertions { insertions = session.insertions }
        if deletions != session.deletions { deletions = session.deletions }

        switch status {
        case .creating:
            // First time we see it Up, flip to running. Otherwise leave as .creating
            // so the splash keeps showing until the container is actually ready.
            if session.running {
                status = .running
                appendLog("Ready")
            }
        case .deleting:
            // Kill is in-flight. We only transition OUT of .deleting when the
            // session disappears from the server list — that's handled in
            // SessionStore, not here.
            break
        case .running, .stopped:
            status = session.running ? .running : .stopped
        }
    }

    public func appendLog(_ line: String) {
        statusLog.append(line)
        // Cap log to keep UI snappy; lifecycle logs don't need to be infinite.
        if statusLog.count > 200 {
            statusLog.removeFirst(statusLog.count - 200)
        }
    }
}
