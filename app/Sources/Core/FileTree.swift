import Foundation

/// A node in the repo file tree. Directories have children; files are leaves.
public final class FileNode: Sendable {
    public let name: String
    public let path: String        // relative to repo root
    public let isDirectory: Bool
    public let children: [FileNode]

    public init(name: String, path: String, isDirectory: Bool, children: [FileNode] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }

    /// Build a tree from a flat list of relative file paths (e.g. from `git ls-files` or `find`).
    /// Paths like `src/main.swift` become nested FileNode directories.
    public static func buildTree(from paths: [String]) -> [FileNode] {
        // Intermediate mutable tree
        let root = MutableNode(name: "", path: "", isDir: true)

        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let components = trimmed.split(separator: "/").map(String.init)
            var current = root
            for (i, component) in components.enumerated() {
                let isLast = i == components.count - 1
                let childPath = components[0...i].joined(separator: "/")
                if let existing = current.childMap[component] {
                    current = existing
                } else {
                    let node = MutableNode(name: component, path: childPath, isDir: !isLast)
                    current.childMap[component] = node
                    current.orderedChildren.append(node)
                    current = node
                }
                // If we're at an intermediate component that was previously a file, upgrade to dir
                if !isLast && !current.isDir {
                    current.isDir = true
                }
            }
        }

        // freeze() sorts children recursively — calling it on root sorts the top level too.
        return root.freeze().children
    }
}

/// Mutable helper for building the tree.
private final class MutableNode {
    var name: String
    var path: String
    var isDir: Bool
    var childMap: [String: MutableNode] = [:]
    var orderedChildren: [MutableNode] = []

    init(name: String, path: String, isDir: Bool) {
        self.name = name
        self.path = path
        self.isDir = isDir
    }

    /// 0 = hidden folder, 1 = folder, 2 = hidden file, 3 = file
    static func sortGroup(_ node: MutableNode) -> Int {
        switch (node.isDir, node.name.hasPrefix(".")) {
        case (true, true):   return 0  // hidden folder
        case (true, false):  return 1  // folder
        case (false, true):  return 2  // hidden file
        case (false, false): return 3  // file
        }
    }

    func freeze() -> FileNode {
        let sorted = orderedChildren.sorted { a, b in
            let aGroup = Self.sortGroup(a)
            let bGroup = Self.sortGroup(b)
            if aGroup != bGroup { return aGroup < bGroup }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return FileNode(
            name: name,
            path: path,
            isDirectory: isDir,
            children: sorted.map { $0.freeze() }
        )
    }
}
