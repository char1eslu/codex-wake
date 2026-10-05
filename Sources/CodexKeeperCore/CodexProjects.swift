import Foundation

/// A project as the Codex client defines it in `.codex-global-state.json`.
package struct CodexProject: Identifiable, Hashable {
    package let id: String
    package let name: String
    package let rootPaths: [String]

    /// Primary directory: the move destination, and what the sidebar shows.
    package var path: String { rootPaths.first ?? "" }

    package init(id: String, name: String, rootPaths: [String]) {
        self.id = id
        self.name = name
        self.rootPaths = rootPaths
    }
}

/// The client's own project model, read from `~/.codex/.codex-global-state.json`.
///
/// Codex Desktop files a chat through `thread-project-assignments`; it does not
/// group by `threads.cwd`. That column records the directory a chat was
/// *launched* in and is never rewritten when the chat is filed elsewhere, so
/// grouping by it both over-counts the launch directory and hides projects
/// whose members were launched somewhere else.
///
/// Observed on a real store: two chats launched in `~/Downloads` and filed under
/// `~/.../Downloads/Pulmonary-nodule_peripheral-blood` were counted in
/// `~/Downloads` as well, and the `Pulmonary-nodule_peripheral-blood` project
/// did not exist in the sidebar at all — 4 chats where the client and magpie
/// both showed 2.
///
/// An assignment pointing at a project that no longer exists resolves to `nil`,
/// which drops the chat back to `cwd` grouping rather than inventing a project.
package struct CodexProjectCatalog {
    package let projects: [String: CodexProject]
    /// Sidebar order the client recorded, outermost first.
    package let order: [String]

    private let assignments: [String: String]
    private let projectIDByRootPath: [String: String]

    package init(globalState: [String: Any]) {
        var projects: [String: CodexProject] = [:]
        var projectIDByRootPath: [String: String] = [:]
        for (id, value) in (globalState["local-projects"] as? [String: Any]) ?? [:] {
            guard let value = value as? [String: Any] else { continue }
            let rootPaths = (value["rootPaths"] as? [String]) ?? []
            let rawName = (value["name"] as? String) ?? ""
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[id] = CodexProject(
                id: id,
                name: name.isEmpty ? id : name,
                rootPaths: rootPaths
            )
            // Several projects can share a root path in principle; the first one
            // wins, which matches how `move` resolves a destination project.
            for root in rootPaths where !root.isEmpty {
                let key = Self.normalized(root)
                if projectIDByRootPath[key] == nil { projectIDByRootPath[key] = id }
            }
        }

        var assignments: [String: String] = [:]
        for (threadID, value) in (globalState["thread-project-assignments"] as? [String: Any]) ?? [:] {
            guard let value = value as? [String: Any],
                  let projectID = value["projectId"] as? String,
                  !projectID.isEmpty
            else { continue }
            assignments[threadID] = projectID
        }

        self.projects = projects
        self.order = (globalState["project-order"] as? [String]) ?? []
        self.assignments = assignments
        self.projectIDByRootPath = projectIDByRootPath
    }

    /// Project the client filed this chat under.
    ///
    /// `nil` when the client filed it nowhere, or when it points at a project
    /// that is no longer in `local-projects`.
    package func project(forThread threadID: String) -> CodexProject? {
        guard let id = assignments[threadID] else { return nil }
        return projects[id]
    }

    /// Project to file a chat under: the client's explicit assignment first, then
    /// the project that owns the chat's launch directory.
    ///
    /// The second step is what keeps the sidebar from listing a project twice.
    /// An assigned chat groups under the project **id** while an unassigned chat
    /// launched in the same directory would group under the raw **path** — two
    /// keys, two rows, one project, its chats split between them. On a real store
    /// that produced `Treadstone 26 + manuscript 18` for a single directory.
    package func project(forThread threadID: String, launchedIn cwd: String) -> CodexProject? {
        if let assigned = project(forThread: threadID) { return assigned }
        return project(owningRootPath: cwd)
    }

    package func project(id: String) -> CodexProject? { projects[id] }

    /// Project owning `path`, matched against an exact `rootPaths` entry.
    ///
    /// Matching is on the whole path, never a substring: on a real store nine
    /// projects lived under a `Downloads/` parent, so a substring test folded
    /// unrelated projects together.
    package func project(owningRootPath path: String) -> CodexProject? {
        guard !path.isEmpty else { return nil }
        return projectIDByRootPath[Self.normalized(path)].flatMap { projects[$0] }
    }

    package var orderedProjects: [CodexProject] {
        order.compactMap { projects[$0] }
    }

    /// Same canonicalisation `move` uses when it resolves a destination project,
    /// so a chat and its project cannot disagree about `/private` prefixes or
    /// trailing separators.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
