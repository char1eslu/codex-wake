import Foundation

package struct CodexThread: Identifiable, Hashable {
    package let id: String
    package let rolloutPath: String
    package let createdAt: Date
    package let updatedAt: Date
    package let createdAtMs: Date?
    package let updatedAtMs: Date?
    package let source: String
    package let threadSource: String
    package let parentThreadID: String?
    package let spawnStatus: String?
    package let childThreadCount: Int
    package let hasUserEvent: Bool
    package let archived: Bool
    package let title: String
    package let sessionIndexTitle: String
    package let firstUserMessage: String
    package let preview: String
    package let cwd: String
    package let isInSessionIndex: Bool
    package let sessionIndexUpdatedAt: Date?
    package let sessionMetaTimestamp: Date?
    package let sessionPayloadTimestamp: Date?
    package let fileExists: Bool
    package let modelProvider: String
    package let model: String?
    package let reasoningEffort: String?
    package let approvalMode: String
    package let sandboxPolicy: String
    package let tokensUsed: Int64
    package let archivedAt: Date?
    package let gitSHA: String?
    package let gitBranch: String?
    package let gitOriginURL: String?
    package let agentNickname: String?
    package let agentRole: String?
    package let agentPath: String?
    package let recencyAt: Date?
    package let historyMode: String?
    package let name: String?
    package let isPinned: Bool
    package let threadSectionID: String?
    package let sectionPosition: Int64?
    package let sectionEnteredAt: Date?
    package let childThreadIDs: [String]

    package init(
        id: String,
        rolloutPath: String,
        createdAt: Date,
        updatedAt: Date,
        createdAtMs: Date?,
        updatedAtMs: Date?,
        source: String,
        threadSource: String,
        parentThreadID: String?,
        spawnStatus: String?,
        childThreadCount: Int,
        hasUserEvent: Bool,
        archived: Bool,
        title: String,
        sessionIndexTitle: String,
        firstUserMessage: String,
        preview: String,
        cwd: String,
        isInSessionIndex: Bool,
        sessionIndexUpdatedAt: Date?,
        sessionMetaTimestamp: Date?,
        sessionPayloadTimestamp: Date?,
        fileExists: Bool,
        modelProvider: String = "",
        model: String? = nil,
        reasoningEffort: String? = nil,
        approvalMode: String = "",
        sandboxPolicy: String = "",
        tokensUsed: Int64 = 0,
        archivedAt: Date? = nil,
        gitSHA: String? = nil,
        gitBranch: String? = nil,
        gitOriginURL: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        agentPath: String? = nil,
        recencyAt: Date? = nil,
        historyMode: String? = nil,
        name: String? = nil,
        isPinned: Bool = false,
        threadSectionID: String? = nil,
        sectionPosition: Int64? = nil,
        sectionEnteredAt: Date? = nil,
        childThreadIDs: [String] = []
    ) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.source = source
        self.threadSource = threadSource
        self.parentThreadID = parentThreadID
        self.spawnStatus = spawnStatus
        self.childThreadCount = childThreadCount
        self.hasUserEvent = hasUserEvent
        self.archived = archived
        self.title = title
        self.sessionIndexTitle = sessionIndexTitle
        self.firstUserMessage = firstUserMessage
        self.preview = preview
        self.cwd = cwd
        self.isInSessionIndex = isInSessionIndex
        self.sessionIndexUpdatedAt = sessionIndexUpdatedAt
        self.sessionMetaTimestamp = sessionMetaTimestamp
        self.sessionPayloadTimestamp = sessionPayloadTimestamp
        self.fileExists = fileExists
        self.modelProvider = modelProvider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.approvalMode = approvalMode
        self.sandboxPolicy = sandboxPolicy
        self.tokensUsed = tokensUsed
        self.archivedAt = archivedAt
        self.gitSHA = gitSHA
        self.gitBranch = gitBranch
        self.gitOriginURL = gitOriginURL
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
        self.recencyAt = recencyAt
        self.historyMode = historyMode
        self.name = name
        self.isPinned = isPinned
        self.threadSectionID = threadSectionID
        self.sectionPosition = sectionPosition
        self.sectionEnteredAt = sectionEnteredAt
        self.childThreadIDs = childThreadIDs
    }

    package var rolloutURL: URL { URL(fileURLWithPath: rolloutPath) }
    package var shortTitle: String {
        for candidate in [sessionIndexTitle, title, firstUserMessage] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.oneLine.prefixString(80)
            }
        }
        return id
    }

    package var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    package var projectID: String {
        ProjectSummary.projectID(for: cwd)
    }

    package var isSubagent: Bool {
        threadSource.caseInsensitiveCompare("subagent") == .orderedSame || parentThreadID != nil
    }

    package var isUserFacing: Bool {
        !isSubagent
    }

    package var needsRepair: Bool {
        if archived { return false }
        if !fileExists { return false }
        if isSubagent || !hasUserEvent { return false }
        return !isInSessionIndex
    }

    package var isAvailable: Bool {
        !archived && fileExists && isInSessionIndex
    }

    package var statusLabel: String {
        if archived { return "Archived" }
        if !fileExists { return "Missing file" }
        if isSubagent { return "Subagent" }
        if !isInSessionIndex { return "Not indexed" }
        return "Available"
    }

    package var activityAt: Date {
        recencyAt ?? updatedAt
    }

    package func matchesMetadata(_ query: String) -> Bool {
        let q = query.lowercased()
        return id.lowercased().contains(q)
            || sessionIndexTitle.lowercased().contains(q)
            || title.lowercased().contains(q)
            || firstUserMessage.lowercased().contains(q)
            || preview.lowercased().contains(q)
            || cwd.lowercased().contains(q)
            || rolloutPath.lowercased().contains(q)
    }
}

package struct ProjectSummary: Identifiable, Hashable {
    package static let allID = "__all__"
    package static let chatsID = "__chats__"
    package static let all = ProjectSummary(id: allID, name: "All Projects", path: "", totalCount: 0, repairCount: 0, availableCount: 0, latestUpdatedAt: nil)
    private static let codexChatsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("Codex", isDirectory: true)
        .standardizedFileURL

    package let id: String
    package let name: String
    package let path: String
    package let totalCount: Int
    package let repairCount: Int
    package let availableCount: Int
    package let latestUpdatedAt: Date?

    package init(
        id: String,
        name: String,
        path: String,
        totalCount: Int,
        repairCount: Int,
        availableCount: Int,
        latestUpdatedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.totalCount = totalCount
        self.repairCount = repairCount
        self.availableCount = availableCount
        self.latestUpdatedAt = latestUpdatedAt
    }

    package var systemImage: String {
        switch id {
        case Self.allID: return "tray.full"
        case Self.chatsID: return "text.bubble"
        default: return "folder"
        }
    }

    package var isSynthetic: Bool {
        id == Self.allID || id == Self.chatsID
    }

    package static func projectID(for cwd: String) -> String {
        isCodexChatPath(cwd) ? chatsID : cwd
    }

    package static func projectName(for cwd: String) -> String {
        if isCodexChatPath(cwd) {
            return "Chats"
        }
        return URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func isCodexChatPath(_ cwd: String) -> Bool {
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let root = codexChatsRoot.path
        return path == root || path.hasPrefix(root + "/")
    }

    package static func make(from threads: [CodexThread], sort: ProjectSortMode = .recent) -> [ProjectSummary] {
        let grouped = Dictionary(grouping: threads) { $0.projectID }
        let projects = grouped.map { projectID, items -> ProjectSummary in
            let firstCWD = items.first?.cwd ?? projectID
            return ProjectSummary(
                id: projectID,
                name: projectName(for: firstCWD),
                path: projectID == chatsID ? "" : projectID,
                totalCount: items.count,
                repairCount: items.filter(\.needsRepair).count,
                availableCount: items.filter(\.isAvailable).count,
                latestUpdatedAt: items.map(\.activityAt).max()
            )
        }
        let pinnedChats = projects.filter { $0.id == chatsID }
        let regularProjects = projects.filter { $0.id != chatsID }
        .sorted { lhs, rhs in
            switch sort {
            case .recent:
                let lhsDate = lhs.latestUpdatedAt ?? .distantPast
                let rhsDate = rhs.latestUpdatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .name:
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return (lhs.latestUpdatedAt ?? .distantPast) > (rhs.latestUpdatedAt ?? .distantPast)
            }
        }
        let all = ProjectSummary(
            id: allID,
            name: "All Projects",
            path: "",
            totalCount: threads.count,
            repairCount: threads.filter(\.needsRepair).count,
            availableCount: threads.filter(\.isAvailable).count,
            latestUpdatedAt: threads.map(\.activityAt).max()
        )
        return pinnedChats + [all] + regularProjects
    }
}

package enum ProjectSortMode: String, CaseIterable, Identifiable {
    case recent
    case name

    package var id: String { rawValue }
}

package struct ActiveStateRoot: Hashable {
    package enum Kind: String {
        case modern
        case legacy
    }

    package let kind: Kind
    package let path: String

    package var label: String {
        kind.rawValue
    }

    package var displayName: String {
        switch kind {
        case .modern: return "Modern"
        case .legacy: return "Legacy"
        }
    }
}

package struct StateRootStatus: Hashable {
    package let kind: ActiveStateRoot.Kind
    package let path: String
    package let isPrimary: Bool
    package let exists: Bool
}

package struct CodexDiagnostics: Hashable {
    package let codexHome: String
    package let sessionIndexPath: String
    package let sessionIndexExists: Bool
    package let sessionsPath: String
    package let sessionsExists: Bool
    package let stateRoots: [StateRootStatus]
    package let activeStateRoot: ActiveStateRoot?
    package let threadCount: Int
    package let projectCount: Int
    package let backupCount: Int
    package let trashCount: Int
}

package struct WakePlan: Hashable {
    package let threadID: String
    package let title: String
    package let project: String
    package let projectPath: String
    package let updatedAt: Date
    package let rolloutPath: String
    package let sessionIndexPath: String
    package let stateDatabasePaths: [String]

    package init(
        threadID: String,
        title: String,
        project: String,
        projectPath: String,
        updatedAt: Date,
        rolloutPath: String,
        sessionIndexPath: String,
        stateDatabasePaths: [String]
    ) {
        self.threadID = threadID
        self.title = title
        self.project = project
        self.projectPath = projectPath
        self.updatedAt = updatedAt
        self.rolloutPath = rolloutPath
        self.sessionIndexPath = sessionIndexPath
        self.stateDatabasePaths = stateDatabasePaths
    }
}

package struct ThreadPreview: Identifiable {
    package var id: String { threadID }
    package let threadID: String
    package let messages: [PreviewMessage]
    package let rawError: String?

    package init(threadID: String, messages: [PreviewMessage], rawError: String?) {
        self.threadID = threadID
        self.messages = messages
        self.rawError = rawError
    }
}

package struct PreviewMessage: Identifiable, Hashable {
    package let id = UUID()
    package let role: String
    package let text: String
    package let timestamp: String?
    package let lineNumber: Int?
    package let branchLineNumber: Int?
    package let isTurnStart: Bool
    package let isSteered: Bool
    package let isFirstVisibleUserMessage: Bool

    package init(
        role: String,
        text: String,
        timestamp: String?,
        lineNumber: Int?,
        branchLineNumber: Int?,
        isTurnStart: Bool,
        isSteered: Bool,
        isFirstVisibleUserMessage: Bool
    ) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.lineNumber = lineNumber
        self.branchLineNumber = branchLineNumber
        self.isTurnStart = isTurnStart
        self.isSteered = isSteered
        self.isFirstVisibleUserMessage = isFirstVisibleUserMessage
    }

    package var canTrimFromHere: Bool {
        (lineNumber ?? 0) > 1 && !isFirstVisibleUserMessage
    }

    package var canBranchFromHere: Bool {
        isTurnStart && (branchLineNumber ?? 0) > 2
    }

    package var isContextMessage: Bool {
        let normalizedRole = role.lowercased()
        let normalizedText = text.lowercased()
        return normalizedRole == "developer"
            || normalizedRole == "system"
            || normalizedText.hasPrefix("<environment_context>")
            || normalizedText.hasPrefix("<permissions instructions>")
            || normalizedText.hasPrefix("<app-context>")
    }
}

package struct WakeReport: Identifiable {
    package let id = UUID()
    package let threadID: String
    package let timestamp: String
    package let backups: [String]
    package let changedFiles: [String]
}

package struct TrimReport: Identifiable {
    package let id = UUID()
    package let threadID: String
    package let timestamp: String
    package let deletedFromLine: Int
    package let removedLineCount: Int
    package let backups: [String]
    package let changedFiles: [String]
}

package struct BranchReport: Identifiable {
    package let id = UUID()
    package let sourceThreadID: String
    package let newThreadID: String
    package let title: String
    package let createdFromLine: Int
    package let keptLineCount: Int
    package let rolloutPath: String
    package let timestamp: String
    package let backups: [String]
    package let changedFiles: [String]
}

package struct MoveReport: Identifiable {
    package let id = UUID()
    package let threadID: String
    package let fromProject: String
    package let toProject: String
    package let timestamp: String
    package let backups: [String]
    package let changedFiles: [String]
}

package struct TrashThreadReport: Identifiable {
    package let id = UUID()
    package let threadID: String
    package let title: String
    package let rolloutPath: String
    package let trashedPath: String?
    package let timestamp: String
    package let backups: [String]
    package let changedFiles: [String]
}

package struct OperationReport: Identifiable {
    package let id = UUID()
    package let title: String
    package let threadIDs: Set<String>
    package let timestamp: String
    package let summary: String
    package let backups: [String]
    package let changedFiles: [String]
    package let failures: [String]

    package init(
        title: String,
        threadIDs: Set<String>,
        timestamp: String,
        summary: String,
        backups: [String],
        changedFiles: [String],
        failures: [String]
    ) {
        self.title = title
        self.threadIDs = threadIDs
        self.timestamp = timestamp
        self.summary = summary
        self.backups = backups
        self.changedFiles = changedFiles
        self.failures = failures
    }
}

package struct BackupFile: Identifiable, Hashable {
    package var id: String { backupPath }

    package let backupPath: String
    package let originalPath: String
    package let originalName: String
    package let directory: String
    package let stamp: String
    package let createdAt: Date?
    package let modifiedAt: Date?
    package let size: Int64
    package let kind: BackupKind
    package let originalExists: Bool
    package let chatTitle: String?
    package let reason: String

    package var path: String { backupPath }
    package var url: URL { URL(fileURLWithPath: backupPath) }

    package var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

package struct TrashedThread: Identifiable, Hashable {
    package var id: String { threadID }

    package let threadID: String
    package let title: String
    package let originalPath: String
    package let trashPath: String?
    package let manifestPath: String
    package let cwd: String
    package let trashedAt: Date?
    package let size: Int64
    package let originalExists: Bool

    package var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

package enum BackupKind: String, Hashable {
    case stateDatabase
    case sessionIndex
    case chatFile
    case other

    package var label: String {
        switch self {
        case .stateDatabase: return "State DB"
        case .sessionIndex: return "Session index"
        case .chatFile: return "Chat file"
        case .other: return "Other"
        }
    }

    package var systemImage: String {
        switch self {
        case .stateDatabase: return "cylinder.split.1x2"
        case .sessionIndex: return "list.bullet.rectangle"
        case .chatFile: return "text.bubble"
        case .other: return "doc"
        }
    }
}

package extension String {
    var oneLine: String {
        split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func prefixString(_ count: Int) -> String {
        if self.count <= count { return self }
        return String(prefix(count)) + "..."
    }
}
