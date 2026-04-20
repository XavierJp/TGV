import Foundation
import Combine

/// Client-side store for all session state. Owns the polling loops, reconciles
/// `SessionManager.listSessions()` into `SessionState` entities, and serves as the
/// single source of truth the UI observes.
@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [String: SessionState] = [:]
    @Published public private(set) var orderedNames: [String] = []
    @Published public private(set) var sessionsRefreshedAt: Date?
    @Published public private(set) var isConnected: Bool = true
    @Published public private(set) var activeSessionName: String?

    /// Bumps every second. Views observe this to re-evaluate per-session staleness
    /// without needing their own timer.
    @Published public private(set) var heartbeat: Int = 0

    public var activeSession: SessionState? { activeSessionName.flatMap { sessions[$0] } }

    public var orderedSessions: [SessionState] {
        orderedNames.compactMap { sessions[$0] }
    }

    public static let listInterval: TimeInterval = 30.0
    public static let activeInterval: TimeInterval = 3.0
    public static let heartbeatInterval: TimeInterval = 1.0

    private let manager: SessionManager
    private let repoURL: String

    private var listTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    public init(manager: SessionManager, repoURL: String) {
        self.manager = manager
        self.repoURL = repoURL
    }

    // MARK: - Lifecycle

    public func start() {
        if listTask == nil {
            listTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshSessionList()
                    try? await Task.sleep(nanoseconds: UInt64(Self.listInterval * 1_000_000_000))
                }
            }
        }
        if heartbeatTask == nil {
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                    await MainActor.run { self?.heartbeat &+= 1 }
                }
            }
        }
    }

    public func stop() {
        listTask?.cancel(); listTask = nil
        activeTask?.cancel(); activeTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
    }

    // MARK: - Active selection

    public func setActive(_ name: String?) {
        activeSessionName = name
        restartActiveTask()
    }

    private func restartActiveTask() {
        activeTask?.cancel(); activeTask = nil
        guard let state = activeSession, state.status == .running else { return }
        activeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshActive()
                try? await Task.sleep(nanoseconds: UInt64(Self.activeInterval * 1_000_000_000))
            }
        }
    }

    private func ensureActiveTaskMatchesStatus() {
        let shouldRun = (activeSession?.status == .running)
        let running = (activeTask != nil)
        if shouldRun && !running {
            restartActiveTask()
        } else if !shouldRun && running {
            activeTask?.cancel(); activeTask = nil
        }
    }

    // MARK: - Mutations

    /// Spawn a new session from a user-supplied title and prompt. Returns the
    /// created `SessionState` synchronously — the CREATING entity is inserted
    /// into the store immediately, before the docker run completes on the
    /// server, so the UI can show a splash + live log.
    /// - The branch is derived from the title (slug + short hex).
    /// - The title is stored as the session's displayName (local + server).
    /// - The prompt is passed to codex when tmux first starts in the container.
    @discardableResult
    public func spawn(title: String, prompt: String) -> SessionState {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = SessionManager.branchFromTitle(trimmedTitle)
        let name = SessionManager.makeSessionName(repoURL: repoURL)
        let state = SessionState(
            name: name,
            repo: repoURL,
            branch: branch,
            displayName: trimmedTitle.isEmpty ? nil : trimmedTitle,
            status: .creating
        )
        state.appendLog("Spawning '\(trimmedTitle)' on \(branch)…")
        sessions[name] = state
        recomputeOrder()

        // `onStep` is sync @Sendable — the only way to hop to MainActor from it
        // is an unstructured Task. Lift it out so the spawn call reads cleanly.
        let appendLog: @Sendable (String) -> Void = { [weak self] step in
            Task { @MainActor in self?.sessions[name]?.appendLog(step) }
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.manager.spawn(name: name, branch: branch, prompt: prompt, onStep: appendLog)
                if !trimmedTitle.isEmpty {
                    try? await self.manager.rename(name: name, displayName: trimmedTitle)
                }
                // Kick an immediate list refresh so the CREATING row can flip to
                // RUNNING as soon as docker reports the container Up.
                await self.refreshSessionList()
            } catch {
                appendLog("✕ \(error)")
            }
        }
        return state
    }

    public func kill(name: String) {
        guard let state = sessions[name] else { return }
        state.status = .deleting
        state.appendLog("Stopping…")
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.manager.stop(name: name)
            } catch {
                self.sessions[name]?.appendLog("✕ \(error)")
            }
            await self.refreshSessionList()
        }
    }

    public func rename(name: String, displayName: String) {
        guard let state = sessions[name] else { return }
        state.displayName = displayName
        recomputeOrder()
        Task { [weak self] in
            guard let self = self else { return }
            try? await self.manager.rename(name: name, displayName: displayName)
        }
    }

    // MARK: - Polling

    public func refreshSessionList() async {
        do {
            let listed = try await manager.listSessions()
            reconcile(listed)
            sessionsRefreshedAt = Date()
            isConnected = true
        } catch {
            isConnected = false
        }
    }

    public func refreshActive() async {
        guard let name = activeSessionName,
              let state = sessions[name],
              state.status == .running else { return }
        do {
            async let statusTask = manager.gitStatusRaw(container: name)
            async let logTask = manager.gitLogRaw(container: name, count: 20)
            async let filesTask = manager.fileListRaw(container: name)
            let (statusRaw, logRaw, filesRaw) = try await (statusTask, logTask, filesTask)

            let parsed = GitStatus.parse(statusRaw)
            let parsedCommits = GitStatus.parseLog(logRaw)
            let paths = filesRaw.components(separatedBy: "\n").filter { !$0.isEmpty }
            let tree = FileNode.buildTree(from: paths)

            // Guard against the active session changing while we awaited
            guard let current = sessions[name], current === state else { return }
            let now = Date()
            current.gitStatus = parsed
            current.commits = parsedCommits
            current.gitRefreshedAt = now
            current.filePaths = paths
            current.fileTree = tree
            current.filesRefreshedAt = now
            isConnected = true
        } catch {
            isConnected = false
        }
    }

    // MARK: - Reconciliation

    private func reconcile(_ listed: [Session]) {
        let listedByName = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0) })

        for (name, session) in listedByName {
            if let existing = sessions[name] {
                existing.applyListed(session)
            } else {
                let state = SessionState(
                    name: name,
                    repo: session.repo,
                    branch: session.branch,
                    displayName: session.displayName,
                    status: session.running ? .running : .stopped
                )
                state.insertions = session.insertions
                state.deletions = session.deletions
                sessions[name] = state
            }
        }

        // Prune local entries the server no longer reports — except CREATING ones,
        // which we keep until the container registers (server list can lag the
        // docker-run by a tick).
        for name in Array(sessions.keys) where listedByName[name] == nil {
            guard let local = sessions[name] else { continue }
            switch local.status {
            case .creating:
                continue
            case .deleting, .running, .stopped:
                sessions.removeValue(forKey: name)
                if activeSessionName == name {
                    activeSessionName = nil
                }
            }
        }

        recomputeOrder()
        ensureActiveTaskMatchesStatus()
    }

    private func recomputeOrder() {
        orderedNames = sessions.values
            .sorted { a, b in
                a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
            .map(\.name)
    }
}
