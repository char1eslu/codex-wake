import Foundation
import SQLite3

package final class CodexStore: ThreadStore, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let codexHome: URL
    private let stateDB: URL
    private let sessionIndex: URL
    private let globalState: URL
    private let backupTrash: URL
    private let threadTrash: URL

    package init(codexHome: URL? = nil) {
        let home = codexHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.codexHome = home
        self.stateDB = home.appendingPathComponent("sqlite", isDirectory: true).appendingPathComponent("state_5.sqlite")
        self.sessionIndex = home.appendingPathComponent("session_index.jsonl")
        self.globalState = home.appendingPathComponent(".codex-global-state.json")
        self.backupTrash = home.appendingPathComponent(".codex-wake-trash", isDirectory: true)
        self.threadTrash = backupTrash.appendingPathComponent("threads", isDirectory: true)
    }

    package func loadActiveStateRoot() throws -> ActiveStateRoot? {
        guard fileManager.fileExists(atPath: stateDB.path) else { return nil }
        try validateStateDatabase(stateDB)
        return ActiveStateRoot(kind: .modern, path: stateDB.path)
    }

    package func diagnostics() throws -> CodexDiagnostics {
        let threads = try loadThreads()
        let projects = ProjectSummary.make(from: threads)
        let backups = (try? loadBackups()) ?? []
        let backupTrash = (try? loadBackupTrash()) ?? []
        let threadTrash = (try? loadThreadTrash()) ?? []
        let stateExists = fileManager.fileExists(atPath: stateDB.path)
        let stateStatus = StateRootStatus(
            kind: .modern,
            path: stateDB.path,
            isPrimary: true,
            exists: stateExists
        )
        return CodexDiagnostics(
            codexHome: codexHome.path,
            sessionIndexPath: sessionIndex.path,
            sessionIndexExists: fileManager.fileExists(atPath: sessionIndex.path),
            sessionsPath: codexHome.appendingPathComponent("sessions", isDirectory: true).path,
            sessionsExists: fileManager.fileExists(atPath: codexHome.appendingPathComponent("sessions", isDirectory: true).path),
            stateRoots: [stateStatus],
            activeStateRoot: stateExists ? ActiveStateRoot(kind: .modern, path: stateDB.path) : nil,
            threadCount: threads.count,
            projectCount: projects.filter { !$0.isSynthetic }.count,
            backupCount: backups.count,
            trashCount: backupTrash.count + threadTrash.count
        )
    }

    package func wakePlan(for thread: CodexThread) throws -> WakePlan {
        WakePlan(
            threadID: thread.id,
            title: thread.shortTitle,
            project: thread.projectName,
            projectPath: thread.cwd,
            updatedAt: thread.updatedAt,
            rolloutPath: thread.rolloutPath,
            sessionIndexPath: sessionIndex.path,
            stateDatabasePaths: fileManager.fileExists(atPath: stateDB.path) ? [stateDB.path] : []
        )
    }

    package func loadThreads(includeSubagents: Bool) throws -> [CodexThread] {
        guard fileManager.fileExists(atPath: codexHome.path) else { throw WakeError.missingCodexHome(codexHome) }
        guard fileManager.fileExists(atPath: stateDB.path) else { throw WakeError.missingStateDatabase(stateDB) }
        try validateStateDatabase(stateDB)

        let index = try loadSessionIndex()
        let rows = try loadThreadRows(from: stateDB)
        let spawnEdges = try loadSpawnEdges(from: stateDB)
        var childIDsByParent: [String: [String]] = [:]
        for row in rows {
            if let parent = spawnEdges[row.id]?.parentThreadID ?? parentThreadID(from: row.source) {
                childIDsByParent[parent, default: []].append(row.id)
            }
        }
        return rows.map { row in
            let indexEntry = index[row.id]
            let edge = spawnEdges[row.id]
            let parentThreadID = edge?.parentThreadID ?? parentThreadID(from: row.source)
            return CodexThread(
                id: row.id,
                rolloutPath: row.rollout_path,
                createdAt: WakeDates.dateFromSeconds(row.created_at) ?? Date.distantPast,
                updatedAt: WakeDates.dateFromSeconds(row.updated_at) ?? Date.distantPast,
                createdAtMs: WakeDates.dateFromMilliseconds(row.created_at_ms),
                updatedAtMs: WakeDates.dateFromMilliseconds(row.updated_at_ms),
                source: row.source,
                threadSource: row.thread_source ?? "",
                parentThreadID: parentThreadID,
                spawnStatus: edge?.status,
                childThreadCount: childIDsByParent[row.id]?.count ?? 0,
                hasUserEvent: (row.has_user_event ?? 0) != 0,
                archived: (row.archived ?? 0) != 0,
                title: metadataText(row.title, maxLength: 240),
                sessionIndexTitle: metadataText(indexEntry?.thread_name, maxLength: 240),
                firstUserMessage: metadataText(row.first_user_message, maxLength: 500),
                preview: metadataText(row.preview, maxLength: 500),
                cwd: row.cwd,
                isInSessionIndex: indexEntry != nil,
                sessionIndexUpdatedAt: WakeDates.parseISO(indexEntry?.updated_at),
                sessionMetaTimestamp: nil,
                sessionPayloadTimestamp: nil,
                fileExists: fileManager.fileExists(atPath: row.rollout_path),
                modelProvider: row.model_provider,
                model: row.model,
                reasoningEffort: row.reasoning_effort,
                approvalMode: row.approval_mode,
                sandboxPolicy: row.sandbox_policy,
                tokensUsed: row.tokens_used ?? 0,
                archivedAt: WakeDates.dateFromSeconds(row.archived_at),
                gitSHA: row.git_sha,
                gitBranch: row.git_branch,
                gitOriginURL: row.git_origin_url,
                agentNickname: row.agent_nickname,
                agentRole: row.agent_role,
                agentPath: row.agent_path,
                recencyAt: dateFromMillisecondsOrSeconds(milliseconds: row.recency_at_ms, seconds: row.recency_at),
                historyMode: row.history_mode,
                name: row.name,
                isPinned: (row.is_pinned ?? 0) != 0,
                threadSectionID: row.thread_section_id,
                sectionPosition: row.section_position,
                sectionEnteredAt: WakeDates.dateFromMilliseconds(row.section_entered_at_ms),
                childThreadIDs: (childIDsByParent[row.id] ?? []).sorted()
            )
        }
        .filter { includeSubagents || $0.isUserFacing }
        .sorted { $0.activityAt > $1.activityAt }
    }

    package func loadBackups() throws -> [BackupFile] {
        guard fileManager.fileExists(atPath: codexHome.path) else { throw WakeError.missingCodexHome(codexHome) }
        return try scanBackups(in: codexHome, includeTrash: false)
    }

    package func loadBackupTrash() throws -> [BackupFile] {
        guard fileManager.fileExists(atPath: backupTrash.path) else { return [] }
        return try scanBackups(in: backupTrash, includeTrash: true)
    }

    package func loadThreadTrash() throws -> [TrashedThread] {
        guard fileManager.fileExists(atPath: threadTrash.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: threadTrash,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var threads: [TrashedThread] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "manifest.json" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            let manifest = try JSONDecoder().decode(TrashedThreadManifest.self, from: Data(contentsOf: url))
            let trashURL = manifest.trashPath.map { URL(fileURLWithPath: $0) }
            let size = trashURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0
            threads.append(
                TrashedThread(
                    threadID: manifest.threadID,
                    title: manifest.title,
                    originalPath: manifest.originalPath,
                    trashPath: manifest.trashPath,
                    manifestPath: url.path,
                    cwd: manifest.cwd,
                    trashedAt: WakeDates.parseISO(manifest.trashedAt),
                    size: size,
                    originalExists: fileManager.fileExists(atPath: manifest.originalPath)
                )
            )
        }

        return threads.sorted { lhs, rhs in
            let lhsDate = lhs.trashedAt ?? .distantPast
            let rhsDate = rhs.trashedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func scanBackups(in root: URL, includeTrash: Bool) throws -> [BackupFile] {
        let marker = ".codex-rescue-backup-"
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = includeTrash
            ? [.skipsPackageDescendants]
            : [.skipsPackageDescendants, .skipsHiddenFiles]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        let sessionIndexEntries = (try? loadSessionIndex()) ?? [:]
        var backups: [BackupFile] = []
        for case let url as URL in enumerator {
            if !includeTrash && url.path.hasPrefix(backupTrash.path + "/") { continue }
            let fileName = url.lastPathComponent
            guard let markerRange = fileName.range(of: marker) else { continue }

            let originalName = String(fileName[..<markerRange.lowerBound])
            let stamp = String(fileName[markerRange.upperBound...])
            guard !originalName.isEmpty, !stamp.isEmpty else { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }

            let directoryURL = url.deletingLastPathComponent()
            let originalDirectoryURL: URL
            if includeTrash {
                let relativeDirectory = String(directoryURL.path.dropFirst(backupTrash.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                originalDirectoryURL = relativeDirectory.isEmpty
                    ? codexHome
                    : codexHome.appendingPathComponent(relativeDirectory, isDirectory: true)
            } else {
                originalDirectoryURL = directoryURL
            }
            let originalURL = originalDirectoryURL.appendingPathComponent(originalName)
            let kind = backupKind(for: originalName)
            let chatTitle = kind == .chatFile ? backupChatTitle(from: url, sessionIndex: sessionIndexEntries) : nil
            backups.append(
                BackupFile(
                    backupPath: url.path,
                    originalPath: originalURL.path,
                    originalName: originalName,
                    directory: directoryURL.path,
                    stamp: stamp,
                    createdAt: WakeDates.dateFromBackupStamp(stamp),
                    modifiedAt: values?.contentModificationDate,
                    size: Int64(values?.fileSize ?? 0),
                    kind: kind,
                    originalExists: fileManager.fileExists(atPath: originalURL.path),
                    chatTitle: chatTitle,
                    reason: backupReason(for: stamp, kind: kind)
                )
            )
        }

        return backups.sorted { lhs, rhs in
            let lhsDate = lhs.createdAt ?? lhs.modifiedAt ?? .distantPast
            let rhsDate = rhs.createdAt ?? rhs.modifiedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.backupPath.localizedCaseInsensitiveCompare(rhs.backupPath) == .orderedAscending
        }
    }

    package func moveBackupToTrash(_ backup: BackupFile) throws {
        let source = URL(fileURLWithPath: backup.backupPath).standardizedFileURL
        guard source.path.hasPrefix(codexHome.standardizedFileURL.path + "/"),
              source.lastPathComponent.contains(".codex-rescue-backup-")
        else {
            throw WakeError.commandFailed("Refusing to move non-Codex Keeper backup file")
        }

        let sourceDirectory = source.deletingLastPathComponent()
        let relativeDirectory = String(sourceDirectory.path.dropFirst(codexHome.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let destinationDirectory = relativeDirectory.isEmpty
            ? backupTrash
            : backupTrash.appendingPathComponent(relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = uniqueTrashURL(for: source.lastPathComponent, in: destinationDirectory)
        try fileManager.moveItem(at: source, to: destination)
    }

    package func restoreBackup(_ backupFile: BackupFile) throws {
        guard backupFile.kind == .chatFile else {
            throw WakeError.commandFailed("Only chat file backups can be restored.")
        }

        let backupURL = URL(fileURLWithPath: backupFile.backupPath).standardizedFileURL
        let originalURL = URL(fileURLWithPath: backupFile.originalPath).standardizedFileURL
        guard backupURL.path.hasPrefix(codexHome.standardizedFileURL.path + "/"),
              backupURL.lastPathComponent.contains(".codex-rescue-backup-")
        else {
            throw WakeError.commandFailed("Refusing to restore non-Codex Keeper backup file.")
        }
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw WakeError.commandFailed("Backup file no longer exists.")
        }

        try fileManager.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporaryURL = originalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(originalURL.lastPathComponent).codex-wake-restore-\(backupStamp())")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.copyItem(at: backupURL, to: temporaryURL)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if fileManager.fileExists(atPath: originalURL.path) {
            _ = try fileManager.replaceItemAt(originalURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: originalURL)
        }
    }

    package func emptyBackupTrash() throws -> Int {
        guard fileManager.fileExists(atPath: backupTrash.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: backupTrash,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }

        var removed = 0
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(backupTrash.standardizedFileURL.path + "/"),
                  standardized.lastPathComponent.contains(".codex-rescue-backup-")
            else { continue }

            let values = try? standardized.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            try fileManager.removeItem(at: standardized)
            removed += 1
        }
        return removed
    }

    package func loadPreview(for thread: CodexThread) throws -> ThreadPreview {
        guard fileManager.fileExists(atPath: thread.rolloutPath) else {
            throw WakeError.missingThreadFile(thread.rolloutPath)
        }

        let content = try String(contentsOf: URL(fileURLWithPath: thread.rolloutPath), encoding: .utf8)
        var messages: [PreviewMessage] = []
        var currentTurnStartLine: Int?
        var hasVisibleUserMessageInTurn = false
        var visibleUserMessageCount = 0
        var pendingTurnComplete: PreviewMessage?
        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let lineNumber = index + 1

            if let eventType = (obj["payload"] as? [String: Any])?["type"] as? String {
                if obj["type"] as? String == "event_msg", eventType == "task_started" {
                    currentTurnStartLine = lineNumber
                    hasVisibleUserMessageInTurn = false
                    pendingTurnComplete = nil
                } else if obj["type"] as? String == "event_msg", eventType == "task_complete" {
                    if let pendingTurnComplete {
                        messages.append(pendingTurnComplete)
                    }
                    currentTurnStartLine = nil
                    hasVisibleUserMessageInTurn = false
                    pendingTurnComplete = nil
                    continue
                }
            }

            let isTurnStartMessage = currentTurnStartLine != nil && !hasVisibleUserMessageInTurn
            let branchLineNumber = isTurnStartMessage ? currentTurnStartLine : nil
            if let message = extractMessage(
                from: obj,
                lineNumber: lineNumber,
                branchLineNumber: branchLineNumber,
                isTurnStart: isTurnStartMessage,
                isSteered: !isTurnStartMessage && isUserObject(obj),
                isFirstVisibleUserMessage: isUserObject(obj) && visibleUserMessageCount == 0
            ) {
                if message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant" {
                    pendingTurnComplete = message
                    continue
                }
                messages.append(message)
                if message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" {
                    visibleUserMessageCount += 1
                    hasVisibleUserMessageInTurn = true
                }
            }
        }

        return ThreadPreview(threadID: thread.id, messages: messages, rawError: nil)
    }

    package func threadContainsRawText(_ thread: CodexThread, query: String) throws -> Bool {
        guard fileManager.fileExists(atPath: thread.rolloutPath) else { return false }
        guard query.count >= 3 else { return false }
        let handle = try FileHandle(forReadingFrom: thread.rolloutURL)
        defer { try? handle.close() }

        let lowerQuery = query.lowercased()
        // Keep a tail of raw bytes between chunks so a match that straddles a
        // 512KB boundary is not missed, and so a multi-byte UTF-8 character cut
        // at the boundary is re-joined instead of dropping the whole chunk.
        let overlap = max(0, lowerQuery.utf8.count - 1)
        var carry = Data()
        while true {
            if Task.isCancelled { return false }
            let data = handle.readData(ofLength: 512 * 1024)
            if data.isEmpty { return false }
            var buffer = carry
            buffer.append(data)
            if let chunk = String(data: buffer, encoding: .utf8)?.lowercased(),
               chunk.contains(lowerQuery) {
                return true
            }
            // Carry the trailing bytes (including a possibly split character)
            // forward to the next read so a boundary-straddling match survives.
            let tailCount = min(overlap + 3, buffer.count)
            carry = buffer.suffix(tailCount)
        }
    }

    package func wake(thread: CodexThread) throws -> WakeReport {
        guard thread.isUserFacing, thread.hasUserEvent else {
            throw WakeError.commandFailed("Subagent chats cannot be added to the user session index.")
        }
        guard fileManager.fileExists(atPath: thread.rolloutPath) else {
            throw WakeError.missingThreadFile(thread.rolloutPath)
        }

        let stamp = backupStamp()
        let backupSuffix = "\(stamp)-wake"
        var backups: [String] = []
        var changed: [String] = []

        backups += try backupStateFiles(stamp: backupSuffix)
        backups.append(try backup(sessionIndex, suffix: backupSuffix).path)
        backups.append(try backup(thread.rolloutURL, suffix: backupSuffix).path)

        let nowSeconds = Int64(Date().timeIntervalSince1970)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try updateSQLite(threadID: thread.id, updatedAt: nowSeconds, updatedAtMs: nowMs)
        changed.append(stateDB.path)

        try upsertSessionIndex(threadID: thread.id, title: thread.shortTitle, updatedAt: WakeDates.isoNowForIndex())
        changed.append(sessionIndex.path)

        try updateSessionMeta(path: thread.rolloutURL, timestamp: WakeDates.isoNowForJSONL())
        changed.append(thread.rolloutPath)

        return WakeReport(threadID: thread.id, timestamp: stamp, backups: backups, changedFiles: changed)
    }

    package func trim(thread: CodexThread, fromLine lineNumber: Int) throws -> TrimReport {
        guard fileManager.fileExists(atPath: thread.rolloutPath) else {
            throw WakeError.missingThreadFile(thread.rolloutPath)
        }
        guard lineNumber > 1 else {
            throw WakeError.commandFailed("Cannot trim before the first JSONL line.")
        }

        let stamp = backupStamp()
        let rolloutURL = thread.rolloutURL
        let backupPath = try backup(rolloutURL, suffix: "\(stamp)-trim").path

        let content = try String(contentsOf: rolloutURL, encoding: .utf8)
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lineNumber <= lines.count else {
            throw WakeError.commandFailed("Trim line is outside the chat file.")
        }

        let keptLines = Array(lines.prefix(lineNumber - 1))
        let removedLineCount = lines.count - keptLines.count
        let trimmedContent = keptLines.joined(separator: "\n") + "\n"
        try trimmedContent.write(to: rolloutURL, atomically: true, encoding: .utf8)

        return TrimReport(
            threadID: thread.id,
            timestamp: stamp,
            deletedFromLine: lineNumber,
            removedLineCount: removedLineCount,
            backups: [backupPath],
            changedFiles: [thread.rolloutPath]
        )
    }

    package func branch(thread: CodexThread, fromLine lineNumber: Int) throws -> BranchReport {
        guard fileManager.fileExists(atPath: thread.rolloutPath) else {
            throw WakeError.missingThreadFile(thread.rolloutPath)
        }
        guard lineNumber > 1 else {
            throw WakeError.commandFailed("Cannot branch before the first JSONL line.")
        }

        let content = try String(contentsOf: thread.rolloutURL, encoding: .utf8)
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lineNumber <= lines.count else {
            throw WakeError.commandFailed("Branch line is outside the chat file.")
        }

        let keptLines = Array(lines.prefix(lineNumber - 1))
        guard !keptLines.isEmpty else {
            throw WakeError.commandFailed("Branch would create an empty chat.")
        }

        let stamp = backupStamp()
        let now = Date()
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let nowJSONL = WakeDates.isoNowForJSONL()
        let nowIndex = WakeDates.isoNowForIndex()
        let newThreadID = try uniqueThreadID()
        let newTitle = branchTitle(for: thread)
        let newRolloutURL = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(branchDatePath(now), isDirectory: true)
            .appendingPathComponent("rollout-\(branchFileTimestamp(now))-\(newThreadID).jsonl")

        var backups: [String] = []
        var changed: [String] = []
        backups += try backupStateFiles(stamp: "\(stamp)-branch")
        backups.append(try backup(sessionIndex, suffix: "\(stamp)-branch").path)

        let branchedContent = try branchContent(
            from: keptLines,
            newThreadID: newThreadID,
            timestamp: nowJSONL,
            cwd: thread.cwd
        )
        try fileManager.createDirectory(at: newRolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        var insertedSQLiteRow = false
        do {
            try branchedContent.write(to: newRolloutURL, atomically: true, encoding: .utf8)
            changed.append(newRolloutURL.path)

            try insertBranchedSQLiteRow(
                sourceThreadID: thread.id,
                newThreadID: newThreadID,
                rolloutPath: newRolloutURL.path,
                title: newTitle,
                createdAt: nowSeconds,
                updatedAt: nowSeconds,
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
            insertedSQLiteRow = true
            try verifyBranchedSQLiteRow(threadID: newThreadID)
            changed.append(stateDB.path)

            try appendSessionIndex(threadID: newThreadID, title: newTitle, updatedAt: nowIndex)
            changed.append(sessionIndex.path)
        } catch {
            if insertedSQLiteRow {
                try? deleteBranchedSQLiteRow(threadID: newThreadID)
            }
            if fileManager.fileExists(atPath: newRolloutURL.path) {
                try? fileManager.removeItem(at: newRolloutURL)
            }
            throw error
        }

        return BranchReport(
            sourceThreadID: thread.id,
            newThreadID: newThreadID,
            title: newTitle,
            createdFromLine: lineNumber,
            keptLineCount: keptLines.count,
            rolloutPath: newRolloutURL.path,
            timestamp: stamp,
            backups: backups,
            changedFiles: changed
        )
    }

    package func move(thread: CodexThread, to project: ProjectSummary) throws -> MoveReport {
        guard thread.isUserFacing else {
            throw WakeError.commandFailed("Subagent chats follow their parent chat and cannot be moved independently.")
        }
        guard !project.path.isEmpty else {
            throw WakeError.commandFailed("Cannot move to All Projects")
        }
        guard fileManager.fileExists(atPath: thread.rolloutPath) else {
            throw WakeError.missingThreadFile(thread.rolloutPath)
        }

        let stamp = backupStamp()
        let backupSuffix = "\(stamp)-move"
        var backups: [String] = []
        var changed: [String] = []

        guard fileManager.fileExists(atPath: globalState.path) else {
            throw WakeError.commandFailed("Codex global project metadata is missing: \(globalState.path)")
        }
        let originalGlobalState = try Data(contentsOf: globalState)
        let movedGlobalState = try globalStateDataMoving(
            originalGlobalState,
            threadID: thread.id,
            destinationPath: project.path
        )
        let originalRollout = try Data(contentsOf: thread.rolloutURL)
        let movedRollout = try sessionMetaDataMoving(originalRollout, cwd: project.path)

        backups += try backupStateFiles(stamp: backupSuffix)
        backups.append(try backup(globalState, suffix: backupSuffix).path)
        backups.append(try backup(thread.rolloutURL, suffix: backupSuffix).path)

        do {
            try writeDataAtomically(movedGlobalState, to: globalState)
            changed.append(globalState.path)
            try writeDataAtomically(movedRollout, to: thread.rolloutURL)
            changed.append(thread.rolloutPath)
            try updateSQLiteProject(threadID: thread.id, cwd: project.path)
            changed.append(stateDB.path)
        } catch {
            try? writeDataAtomically(originalGlobalState, to: globalState)
            try? writeDataAtomically(originalRollout, to: thread.rolloutURL)
            try? updateSQLiteProject(threadID: thread.id, cwd: thread.cwd)
            throw error
        }

        return MoveReport(
            threadID: thread.id,
            fromProject: thread.cwd,
            toProject: project.path,
            timestamp: stamp,
            backups: backups,
            changedFiles: changed
        )
    }

    package func moveThreadToTrash(_ thread: CodexThread) throws -> TrashThreadReport {
        guard thread.isUserFacing else {
            throw WakeError.commandFailed("Subagent chats follow their parent chat and cannot be deleted independently.")
        }
        let rolloutURL = thread.rolloutURL.standardizedFileURL
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
        let fileExists = fileManager.fileExists(atPath: rolloutURL.path)
        if fileExists && !rolloutURL.path.hasPrefix(sessionsRoot.path + "/") {
            throw WakeError.commandFailed("Refusing to trash a chat file outside ~/.codex/sessions.")
        }

        let sqliteRecord = try loadFullThreadRecord(threadID: thread.id)
        let sessionIndexEntry = try loadSessionIndex()[thread.id]
        let spawnEdges = try loadSpawnEdgesReferencing(threadID: thread.id)
        let dynamicTools = try loadDynamicTools(threadID: thread.id)
        let externalDatabases = try externalDatabaseSnapshots(threadID: thread.id)
        let originalGlobalState = try Data(contentsOf: globalState)
        let removedGlobalState = try globalStateDataRemovingThread(
            originalGlobalState,
            threadID: thread.id
        )
        let stamp = backupStamp()
        let backupSuffix = "\(stamp)-trash-thread"
        var backups: [String] = []
        var changed: [String] = []

        backups += try backupStateFiles(stamp: backupSuffix)
        backups += try backupExternalDatabases(externalDatabases, stamp: backupSuffix)
        backups.append(try backup(globalState, suffix: backupSuffix).path)
        if fileManager.fileExists(atPath: sessionIndex.path) {
            backups.append(try backup(sessionIndex, suffix: backupSuffix).path)
        }

        var trashedPath: String?
        let trashDirectory = threadTrash.appendingPathComponent(thread.id, isDirectory: true)
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        if fileExists {
            let destination = uniqueTrashURL(for: rolloutURL.lastPathComponent, in: trashDirectory)
            try fileManager.moveItem(at: rolloutURL, to: destination)
            trashedPath = destination.path
            changed.append(thread.rolloutPath)
        }

        // The chat file is already moved. If any metadata step below fails,
        // move it back so we never leave the DB pointing at a missing file.
        do {
            let manifest = TrashedThreadManifest(
                version: 2,
                threadID: thread.id,
                title: thread.shortTitle,
                originalPath: thread.rolloutPath,
                trashPath: trashedPath,
                cwd: thread.cwd,
                trashedAt: WakeDates.isoNowForJSONL(),
                sqliteRecord: sqliteRecord,
                sessionIndexEntry: sessionIndexEntry,
                spawnEdges: spawnEdges,
                dynamicTools: dynamicTools,
                projectState: removedGlobalState.projectState,
                externalDatabases: externalDatabases
            )
            try writeTrashManifest(manifest, to: trashDirectory.appendingPathComponent("manifest.json"))

            try writeDataAtomically(removedGlobalState.data, to: globalState)
            changed.append(globalState.path)

            try deleteSQLiteThread(threadID: thread.id)
            changed.append(stateDB.path)

            try deleteExternalDatabaseReferences(externalDatabases, threadID: thread.id)
            changed.append(contentsOf: externalDatabases
                .filter { !$0.rows.isEmpty }
                .map { codexHome.appendingPathComponent($0.relativePath).path })

            if fileManager.fileExists(atPath: sessionIndex.path) {
                try removeSessionIndexEntry(threadID: thread.id)
                changed.append(sessionIndex.path)
            }
        } catch {
            if (try? loadFullThreadRecord(threadID: thread.id)) == nil {
                try? insertFullThreadRecord(sqliteRecord)
                try? restoreRelatedMetadata(spawnEdges: spawnEdges, dynamicTools: dynamicTools)
            }
            try? restoreExternalDatabaseSnapshots(externalDatabases)
            try? writeDataAtomically(originalGlobalState, to: globalState)
            if let sessionIndexEntry {
                try? appendSessionIndexEntry(sessionIndexEntry)
            }
            if let trashedPath, fileExists, !fileManager.fileExists(atPath: rolloutURL.path) {
                try? fileManager.moveItem(at: URL(fileURLWithPath: trashedPath), to: rolloutURL)
            }
            try? fileManager.removeItem(at: trashDirectory)
            throw error
        }

        return TrashThreadReport(
            threadID: thread.id,
            title: thread.shortTitle,
            rolloutPath: thread.rolloutPath,
            trashedPath: trashedPath,
            timestamp: stamp,
            backups: backups,
            changedFiles: changed
        )
    }

    package func restoreTrashedThread(_ thread: TrashedThread) throws {
        let manifestURL = URL(fileURLWithPath: thread.manifestPath).standardizedFileURL
        guard manifestURL.path.hasPrefix(threadTrash.standardizedFileURL.path + "/") else {
            throw WakeError.commandFailed("Refusing to restore a chat outside Codex Keeper trash.")
        }
        let manifest = try JSONDecoder().decode(TrashedThreadManifest.self, from: Data(contentsOf: manifestURL))
        let originalURL = URL(fileURLWithPath: manifest.originalPath).standardizedFileURL
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
        guard originalURL.path.hasPrefix(sessionsRoot.path + "/") else {
            throw WakeError.commandFailed("Refusing to restore a chat outside ~/.codex/sessions.")
        }
        if fileManager.fileExists(atPath: originalURL.path) {
            throw WakeError.commandFailed("Original chat file already exists.")
        }

        let backupSuffix = "\(backupStamp())-before-trash-restore"
        _ = try backupStateFiles(stamp: backupSuffix)
        _ = try backupExternalDatabases(manifest.externalDatabases ?? [], stamp: backupSuffix)
        let currentGlobalState = try Data(contentsOf: globalState)
        if let projectState = manifest.projectState {
            _ = try backup(globalState, suffix: backupSuffix)
            _ = try globalStateDataRestoringThread(
                currentGlobalState,
                threadID: manifest.threadID,
                projectState: projectState
            )
        }
        if fileManager.fileExists(atPath: sessionIndex.path) {
            _ = try backup(sessionIndex, suffix: backupSuffix)
        }

        try fileManager.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let trashPath = manifest.trashPath {
            let trashURL = URL(fileURLWithPath: trashPath).standardizedFileURL
            guard trashURL.path.hasPrefix(threadTrash.standardizedFileURL.path + "/"),
                  fileManager.fileExists(atPath: trashURL.path)
            else {
                throw WakeError.commandFailed("Trashed chat file is missing.")
            }
            try fileManager.copyItem(at: trashURL, to: originalURL)
        }

        do {
            try insertFullThreadRecord(manifest.sqliteRecord)
            try restoreRelatedMetadata(
                spawnEdges: manifest.spawnEdges ?? [],
                dynamicTools: manifest.dynamicTools ?? []
            )
            try restoreExternalDatabaseSnapshots(manifest.externalDatabases ?? [])
            if let entry = manifest.sessionIndexEntry {
                try appendSessionIndexEntry(entry)
            }
            if let projectState = manifest.projectState {
                let restoredGlobalState = try globalStateDataRestoringThread(
                    currentGlobalState,
                    threadID: manifest.threadID,
                    projectState: projectState
                )
                try writeDataAtomically(restoredGlobalState, to: globalState)
            }
            try deleteTrashDirectory(containing: manifestURL)
        } catch {
            try? deleteSQLiteThread(threadID: manifest.threadID)
            try? deleteExternalDatabaseReferences(
                manifest.externalDatabases ?? [],
                threadID: manifest.threadID
            )
            try? removeSessionIndexEntry(threadID: manifest.threadID)
            try? writeDataAtomically(currentGlobalState, to: globalState)
            if !thread.originalExists {
                try? fileManager.removeItem(at: originalURL)
            }
            throw error
        }
    }

    package func deleteTrashedThreadPermanently(_ thread: TrashedThread) throws {
        let manifestURL = URL(fileURLWithPath: thread.manifestPath).standardizedFileURL
        guard manifestURL.path.hasPrefix(threadTrash.standardizedFileURL.path + "/") else {
            throw WakeError.commandFailed("Refusing to delete a file outside Codex Keeper trash.")
        }
        try deleteTrashDirectory(containing: manifestURL)
    }

    package func emptyThreadTrash() throws -> Int {
        guard fileManager.fileExists(atPath: threadTrash.path) else { return 0 }
        let directories = try fileManager.contentsOfDirectory(
            at: threadTrash,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for directory in directories {
            let standardized = directory.standardizedFileURL
            guard standardized.path.hasPrefix(threadTrash.standardizedFileURL.path + "/") else { continue }
            let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            try fileManager.removeItem(at: standardized)
            removed += 1
        }
        return removed
    }

    private func loadThreadRows(from stateDB: URL) throws -> [ThreadRow] {
        do {
            return try loadThreadRows(from: try openReadOnly(stateDB))
        } catch {
            return try loadThreadRows(from: try openReadOnlyImmutable(stateDB))
        }
    }

    private func loadThreadRows(from database: OpaquePointer) throws -> [ThreadRow] {
        defer { sqlite3_close(database) }
        let query = """
        select id, rollout_path, created_at, updated_at, source, coalesce(thread_source, '') as thread_source,
               has_user_event, archived,
               substr(title, 1, 240) as title,
               substr(first_user_message, 1, 500) as first_user_message,
               substr(preview, 1, 500) as preview,
               cwd, created_at_ms, updated_at_ms,
               model_provider, model, reasoning_effort, approval_mode, sandbox_policy,
               tokens_used, archived_at, git_sha, git_branch, git_origin_url,
               agent_nickname, agent_role, agent_path, recency_at, recency_at_ms,
               history_mode, name, is_pinned, thread_section_id, section_position,
               section_entered_at_ms
        from threads
        order by coalesce(nullif(recency_at_ms, 0), nullif(updated_at_ms, 0), updated_at * 1000) desc;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            let message = String(cString: sqlite3_errmsg(database))
            throw WakeError.commandFailed("Cannot prepare SQLite query: \(message)")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [ThreadRow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            rows.append(
                ThreadRow(
                    id: text(statement, 0),
                    rollout_path: text(statement, 1),
                    created_at: int64(statement, 2),
                    updated_at: int64(statement, 3),
                    source: text(statement, 4),
                    thread_source: text(statement, 5),
                    has_user_event: int(statement, 6),
                    archived: int(statement, 7),
                    title: text(statement, 8),
                    first_user_message: nullableText(statement, 9),
                    preview: nullableText(statement, 10),
                    cwd: text(statement, 11),
                    created_at_ms: int64(statement, 12),
                    updated_at_ms: int64(statement, 13),
                    model_provider: text(statement, 14),
                    model: nullableText(statement, 15),
                    reasoning_effort: nullableText(statement, 16),
                    approval_mode: text(statement, 17),
                    sandbox_policy: text(statement, 18),
                    tokens_used: int64(statement, 19),
                    archived_at: int64(statement, 20),
                    git_sha: nullableText(statement, 21),
                    git_branch: nullableText(statement, 22),
                    git_origin_url: nullableText(statement, 23),
                    agent_nickname: nullableText(statement, 24),
                    agent_role: nullableText(statement, 25),
                    agent_path: nullableText(statement, 26),
                    recency_at: int64(statement, 27),
                    recency_at_ms: int64(statement, 28),
                    history_mode: nullableText(statement, 29),
                    name: nullableText(statement, 30),
                    is_pinned: int64(statement, 31),
                    thread_section_id: nullableText(statement, 32),
                    section_position: int64(statement, 33),
                    section_entered_at_ms: int64(statement, 34)
                )
            )
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw WakeError.commandFailed("Cannot read SQLite threads: \(String(cString: sqlite3_errmsg(database)))")
        }
        return rows
    }

    private func loadSpawnEdges(from stateDB: URL) throws -> [String: ThreadSpawnEdgeRecord] {
        let database: OpaquePointer
        do {
            database = try openReadOnly(stateDB)
        } catch {
            database = try openReadOnlyImmutable(stateDB)
        }
        defer { sqlite3_close(database) }

        var existsStatement: OpaquePointer?
        let existsSQL = "select 1 from sqlite_master where type = 'table' and name = 'thread_spawn_edges';"
        guard sqlite3_prepare_v2(database, existsSQL, -1, &existsStatement, nil) == SQLITE_OK,
              let existsStatement
        else { return [:] }
        defer { sqlite3_finalize(existsStatement) }
        guard sqlite3_step(existsStatement) == SQLITE_ROW else { return [:] }

        var statement: OpaquePointer?
        let query = "select parent_thread_id, child_thread_id, status from thread_spawn_edges;"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw WakeError.commandFailed("Cannot read Codex thread parent relationships.")
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: ThreadSpawnEdgeRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let edge = ThreadSpawnEdgeRecord(
                parentThreadID: text(statement, 0),
                childThreadID: text(statement, 1),
                status: text(statement, 2)
            )
            result[edge.childThreadID] = edge
        }
        return result
    }

    private func parentThreadID(from source: String) -> String? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagent = object["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any],
              let parent = spawn["parent_thread_id"] as? String,
              !parent.isEmpty
        else { return nil }
        return parent
    }

    private func backupKind(for originalName: String) -> BackupKind {
        if originalName == "state_5.sqlite" || originalName.hasPrefix("state_5.sqlite-") {
            return .stateDatabase
        }
        if originalName == "session_index.jsonl" {
            return .sessionIndex
        }
        if originalName.hasSuffix(".jsonl") {
            return .chatFile
        }
        return .other
    }

    private func backupReason(for stamp: String, kind: BackupKind) -> String {
        if stamp.contains("-trim") {
            return "Created before Trim from here"
        }
        if stamp.contains("-before-restore") {
            return "Created before Restore"
        }
        if stamp.contains("-wake") {
            return "Created before Repair Index"
        }
        if stamp.contains("-trash-thread") {
            return "Created before Move to Trash"
        }
        if stamp.contains("-move") {
            return "Created before Move"
        }
        if kind == .chatFile {
            return "Created before a chat change (legacy backup)"
        }
        return "Created by Codex Keeper"
    }

    private func backupChatTitle(from url: URL, sessionIndex: [String: SessionIndexEntry]) -> String? {
        guard let prefix = try? readPrefix(of: url, maxBytes: 512 * 1024) else { return nil }
        if let id = firstCapture(in: prefix, pattern: #""payload":\{"id":"([^"]+)""#),
           let title = sessionIndex[id]?.thread_name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title.oneLine.prefixString(100)
        }

        for line in prefix.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = extractMessage(
                    from: obj,
                    lineNumber: 0,
                    branchLineNumber: nil,
                    isTurnStart: false,
                    isSteered: false,
                    isFirstVisibleUserMessage: false
                  ),
                  message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user"
            else { continue }
            return message.text.oneLine.prefixString(100)
        }

        return nil
    }

    private func uniqueTrashURL(for fileName: String, in directory: URL) -> URL {
        var destination = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: destination.path) else { return destination }

        let suffix = backupStamp()
        destination = directory.appendingPathComponent("\(fileName).trashed-\(suffix)")
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(fileName).trashed-\(suffix)-\(counter)")
            counter += 1
        }
        return destination
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func nullableText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func metadataText(_ text: String?, maxLength: Int) -> String {
        (text ?? "")
            .oneLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefixString(maxLength)
    }

    private func int(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func int64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func dateFromMillisecondsOrSeconds(milliseconds: Int64?, seconds: Int64?) -> Date? {
        if let milliseconds, milliseconds > 0 {
            return WakeDates.dateFromMilliseconds(milliseconds)
        }
        if let seconds, seconds > 0 {
            return WakeDates.dateFromSeconds(seconds)
        }
        return nil
    }

    private func loadSessionIndex() throws -> [String: SessionIndexEntry] {
        guard fileManager.fileExists(atPath: sessionIndex.path) else { return [:] }
        let text = try String(contentsOf: sessionIndex, encoding: .utf8)
        var result: [String: SessionIndexEntry] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? JSONDecoder().decode(SessionIndexEntry.self, from: data)
            else { continue }
            result[entry.id] = entry
        }
        return result
    }

    private func readPrefix(of url: URL, maxBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private func extractMessage(
        from obj: [String: Any],
        lineNumber: Int,
        branchLineNumber: Int?,
        isTurnStart: Bool,
        isSteered: Bool,
        isFirstVisibleUserMessage: Bool
    ) -> PreviewMessage? {
        let timestamp = obj["timestamp"] as? String
        guard let payload = obj["payload"] as? [String: Any] else { return nil }

        if let type = payload["type"] as? String, type == "message" {
            let role = payload["role"] as? String ?? "message"
            if role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "developer" {
                return nil
            }
            let text = cleanPreviewText(extractContentText(payload["content"]))
            if !text.isEmpty {
                return PreviewMessage(
                    role: role,
                    text: text,
                    timestamp: timestamp,
                    lineNumber: lineNumber,
                    branchLineNumber: branchLineNumber,
                    isTurnStart: isTurnStart,
                    isSteered: isSteered,
                    isFirstVisibleUserMessage: role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" && isFirstVisibleUserMessage
                )
            }
        }

        if let type = obj["type"] as? String, type == "user_message",
           let text = payload["message"] as? String {
            let cleanedText = cleanPreviewText(text)
            if !cleanedText.isEmpty {
                return PreviewMessage(
                    role: "user",
                    text: cleanedText,
                    timestamp: timestamp,
                    lineNumber: lineNumber,
                    branchLineNumber: branchLineNumber,
                    isTurnStart: isTurnStart,
                    isSteered: isSteered,
                    isFirstVisibleUserMessage: isFirstVisibleUserMessage
                )
            }
        }

        return nil
    }

    private func isUserObject(_ obj: [String: Any]) -> Bool {
        let payload = obj["payload"] as? [String: Any]
        if obj["type"] as? String == "user_message" {
            return true
        }
        return (payload?["type"] as? String) == "message" && (payload?["role"] as? String) == "user"
    }

    private func extractContentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let array = value as? [[String: Any]] else { return "" }
        return array.compactMap { item in
            if let text = item["text"] as? String { return text }
            if let text = item["content"] as? String { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func cleanPreviewText(_ text: String) -> String {
        var result = text
        result = removing(pattern: #"<permissions instructions>.*?</permissions instructions>\s*"#, from: result)
        result = removing(pattern: #"# AGENTS\.md instructions[^\n]*(?:\n|\r\n).*?</INSTRUCTIONS>\s*"#, from: result)
        result = removing(pattern: #"\n{3,}"#, from: result, replacingWith: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removing(pattern: String, from text: String, replacingWith replacement: String = "") -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private func validateStateDatabase(_ stateDB: URL) throws {
        let columns = try loadThreadColumns(in: stateDB)
        let requiredColumns: Set<String> = [
            "id", "rollout_path", "created_at", "updated_at", "source", "model_provider",
            "cwd", "title", "sandbox_policy", "approval_mode", "tokens_used",
            "has_user_event", "archived", "archived_at", "git_sha", "git_branch",
            "git_origin_url", "cli_version", "first_user_message", "agent_nickname",
            "agent_role", "memory_mode", "model", "reasoning_effort", "agent_path",
            "created_at_ms", "updated_at_ms", "thread_source", "preview", "recency_at",
            "recency_at_ms", "history_mode", "name", "is_pinned", "thread_section_id",
            "section_position", "section_entered_at_ms"
        ]
        let missing = requiredColumns.subtracting(columns).sorted()
        guard missing.isEmpty else {
            throw WakeError.commandFailed(
                "Unsupported Codex state schema in \(stateDB.path). Missing columns: \(missing.joined(separator: ", ")). Codex Keeper stopped before changing local metadata."
            )
        }
    }

    private func loadThreadColumns(in stateDB: URL) throws -> Set<String> {
        let database = try openReadOnlyImmutable(stateDB)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "pragma table_info(threads);", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            let message = String(cString: sqlite3_errmsg(database))
            throw WakeError.commandFailed("Cannot inspect SQLite schema in \(stateDB.path): \(message)")
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(statement, 1))
        }
        guard !columns.isEmpty else {
            throw WakeError.commandFailed("Unsupported Codex state schema in \(stateDB.path). Table 'threads' was not found.")
        }
        return columns
    }

    private func backupStateFiles(stamp: String) throws -> [String] {
        // Prefer a consistent SQLite snapshot via VACUUM INTO: it captures all
        // committed WAL content into one standalone file and avoids the torn
        // snapshot risk of copying state/-wal/-shm separately while Codex is
        // running. Falls back to plain file copies if VACUUM is unavailable.
        guard fileManager.fileExists(atPath: stateDB.path) else { return [] }
        let destination = stateDB.deletingLastPathComponent()
            .appendingPathComponent(stateDB.lastPathComponent + ".codex-rescue-backup-" + stamp)
        if let snapshot = try? vacuumSnapshot(of: stateDB, to: destination) {
            return [snapshot.path]
        }
        var paths: [String] = []
        for url in stateFiles(for: stateDB) where fileManager.fileExists(atPath: url.path) {
            paths.append(try backup(url, suffix: stamp).path)
        }
        return paths
    }

    private func openReadOnly(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            throw WakeError.commandFailed("Cannot open SQLite database: \(url.path)")
        }
        return database
    }

    // Some Codex builds leave -shm unreadable. Keep immutable as a fallback;
    // it may be stale because it intentionally ignores uncheckpointed WAL.
    private func openReadOnlyImmutable(_ url: URL) throws -> OpaquePointer {
        var allowed = CharacterSet(charactersIn: "/")
        allowed.formUnion(.alphanumerics)
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        let uri = "file:\(encodedPath)?immutable=1"
        var database: OpaquePointer?
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            throw WakeError.commandFailed("Cannot open SQLite database: \(url.path)")
        }
        return database
    }

    private func vacuumSnapshot(of source: URL, to destination: URL) throws -> URL {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            throw WakeError.commandFailed("Cannot open SQLite database for snapshot: \(source.path)")
        }
        defer { sqlite3_close(database) }

        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, "vacuum into '\(escaped)';", nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            try? fileManager.removeItem(at: destination)
            throw WakeError.commandFailed("VACUUM INTO failed: \(message)")
        }
        return destination
    }

    private func stateFiles(for stateDB: URL) -> [URL] {
        [
            stateDB,
            URL(fileURLWithPath: stateDB.path + "-wal"),
            URL(fileURLWithPath: stateDB.path + "-shm")
        ]
    }

    private func backup(_ url: URL, suffix: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".codex-rescue-backup-" + suffix)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private func writeTrashManifest(_ manifest: TrashedThreadManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func deleteTrashDirectory(containing manifestURL: URL) throws {
        let directory = manifestURL.deletingLastPathComponent().standardizedFileURL
        guard directory.path.hasPrefix(threadTrash.standardizedFileURL.path + "/") else {
            throw WakeError.commandFailed("Refusing to delete a file outside Codex Keeper trash.")
        }
        try fileManager.removeItem(at: directory)
    }

    private func updateSQLite(threadID: String, updatedAt: Int64, updatedAtMs: Int64) throws {
        let sql = """
        update threads
        set thread_source = 'user', updated_at = \(updatedAt), updated_at_ms = \(updatedAtMs)
        where id = '\(threadID.replacingOccurrences(of: "'", with: "''"))';
        """
        _ = try Shell.run("/usr/bin/sqlite3", [stateDB.path, sql])
    }

    private func updateSQLiteProject(threadID: String, cwd: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            stateDB.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw WakeError.commandFailed("Cannot open Codex state database for project move.")
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, "begin immediate;", nil, nil, nil) == SQLITE_OK else {
            throw WakeError.commandFailed("Cannot start Codex project move transaction.")
        }
        let statementSQL = "update threads set cwd = '\(sql(cwd))' where id = '\(sql(threadID))';"
        guard sqlite3_exec(database, statementSQL, nil, nil, nil) == SQLITE_OK,
              sqlite3_changes(database) == 1,
              sqlite3_exec(database, "commit;", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_exec(database, "rollback;", nil, nil, nil)
            throw WakeError.commandFailed("Project move did not update exactly one Codex thread.")
        }
    }

    private func globalStateDataMoving(
        _ data: Data,
        threadID: String,
        destinationPath: String
    ) throws -> Data {
        guard var state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let localProjects = state["local-projects"] as? [String: Any]
        else {
            throw WakeError.invalidJSON("Cannot decode Codex global project metadata")
        }

        let normalizedDestination = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        let destinationProjectID = localProjects.first { _, value in
            guard let project = value as? [String: Any],
                  let roots = project["rootPaths"] as? [String]
            else { return false }
            return roots.contains {
                URL(fileURLWithPath: $0).standardizedFileURL.path == normalizedDestination
            }
        }?.key
        guard let destinationProjectID else {
            throw WakeError.commandFailed("The destination is not a saved Codex project: \(destinationPath)")
        }

        var assignments = state["thread-project-assignments"] as? [String: Any] ?? [:]
        assignments[threadID] = [
            "projectKind": "local",
            "projectId": destinationProjectID
        ]
        state["thread-project-assignments"] = assignments

        var orders = state["sidebar-project-thread-orders"] as? [String: Any] ?? [:]
        for (projectID, value) in orders {
            guard var order = value as? [String: Any] else { continue }
            let ids = (order["threadIds"] as? [String] ?? []).filter { $0 != threadID }
            order["threadIds"] = projectID == destinationProjectID ? [threadID] + ids : ids
            orders[projectID] = order
        }
        if orders[destinationProjectID] == nil {
            orders[destinationProjectID] = ["threadIds": [threadID]]
        }
        state["sidebar-project-thread-orders"] = orders

        if var ids = state["projectless-thread-ids"] as? [String] {
            ids.removeAll { $0 == threadID }
            state["projectless-thread-ids"] = ids
        }
        for key in ["thread-workspace-root-hints", "thread-projectless-output-directories"] {
            if var values = state[key] as? [String: Any] {
                values.removeValue(forKey: threadID)
                state[key] = values
            }
        }

        return try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    }

    private func globalStateDataRemovingThread(
        _ data: Data,
        threadID: String
    ) throws -> (data: Data, projectState: ThreadProjectState) {
        guard let original = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WakeError.invalidJSON("Cannot decode Codex global project metadata")
        }
        let projectState = threadProjectState(from: original, threadID: threadID)
        guard let cleaned = removeThreadReferences(original, threadID: threadID) as? [String: Any] else {
            throw WakeError.invalidJSON("Cannot clean Codex global project metadata")
        }
        return (
            try JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]),
            projectState
        )
    }

    private func globalStateDataRestoringThread(
        _ data: Data,
        threadID: String,
        projectState: ThreadProjectState
    ) throws -> Data {
        guard var state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WakeError.invalidJSON("Cannot decode Codex global project metadata")
        }

        if let projectID = projectState.projectID {
            var assignments = state["thread-project-assignments"] as? [String: Any] ?? [:]
            assignments[threadID] = ["projectKind": "local", "projectId": projectID]
            state["thread-project-assignments"] = assignments
        }

        if let sidebarProjectID = projectState.sidebarProjectID {
            var orders = state["sidebar-project-thread-orders"] as? [String: Any] ?? [:]
            for (projectID, value) in orders {
                guard var order = value as? [String: Any] else { continue }
                order["threadIds"] = (order["threadIds"] as? [String] ?? []).filter { $0 != threadID }
                orders[projectID] = order
            }
            var destination = orders[sidebarProjectID] as? [String: Any] ?? [:]
            var ids = destination["threadIds"] as? [String] ?? []
            let position = min(max(projectState.sidebarPosition ?? 0, 0), ids.count)
            ids.insert(threadID, at: position)
            destination["threadIds"] = ids
            orders[sidebarProjectID] = destination
            state["sidebar-project-thread-orders"] = orders
        }

        if projectState.wasProjectless {
            var ids = state["projectless-thread-ids"] as? [String] ?? []
            if !ids.contains(threadID) { ids.append(threadID) }
            state["projectless-thread-ids"] = ids
        }
        if let hint = projectState.workspaceRootHint {
            var hints = state["thread-workspace-root-hints"] as? [String: Any] ?? [:]
            hints[threadID] = hint
            state["thread-workspace-root-hints"] = hints
        }
        if let output = projectState.outputDirectory {
            var outputs = state["thread-projectless-output-directories"] as? [String: Any] ?? [:]
            outputs[threadID] = output
            state["thread-projectless-output-directories"] = outputs
        }
        return try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    }

    private func threadProjectState(from state: [String: Any], threadID: String) -> ThreadProjectState {
        let assignment = (state["thread-project-assignments"] as? [String: Any])?[threadID] as? [String: Any]
        var sidebarProjectID: String?
        var sidebarPosition: Int?
        if let orders = state["sidebar-project-thread-orders"] as? [String: Any] {
            for (projectID, value) in orders {
                guard let order = value as? [String: Any],
                      let ids = order["threadIds"] as? [String],
                      let position = ids.firstIndex(of: threadID)
                else { continue }
                sidebarProjectID = projectID
                sidebarPosition = position
                break
            }
        }
        return ThreadProjectState(
            projectID: assignment?["projectId"] as? String,
            sidebarProjectID: sidebarProjectID,
            sidebarPosition: sidebarPosition,
            wasProjectless: (state["projectless-thread-ids"] as? [String] ?? []).contains(threadID),
            workspaceRootHint: (state["thread-workspace-root-hints"] as? [String: Any])?[threadID] as? String,
            outputDirectory: (state["thread-projectless-output-directories"] as? [String: Any])?[threadID] as? String
        )
    }

    private func removeThreadReferences(_ value: Any, threadID: String) -> Any? {
        if let string = value as? String {
            return string == threadID ? nil : string
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nestedValue) in dictionary where key != threadID {
                if let string = nestedValue as? String, string == threadID { continue }
                if let cleaned = removeThreadReferences(nestedValue, threadID: threadID) {
                    result[key] = cleaned
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.compactMap { removeThreadReferences($0, threadID: threadID) }
        }
        return value
    }

    private func sessionMetaDataMoving(_ data: Data, cwd: String) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw WakeError.invalidJSON("Cannot decode chat JSONL")
        }
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first,
              let firstData = String(first).data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
        else { throw WakeError.invalidJSON("Cannot decode first JSONL line") }

        var payload = object["payload"] as? [String: Any] ?? [:]
        payload["cwd"] = cwd
        object["payload"] = payload
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let firstLine = String(data: encoded, encoding: .utf8) else {
            throw WakeError.invalidJSON("Cannot encode first JSONL line")
        }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        return Data((firstLine + "\n" + rest).utf8)
    }

    private func writeDataAtomically(_ data: Data, to url: URL) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        try data.write(to: url, options: .atomic)
        if let permissions = attributes?[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private func deleteSQLiteThread(threadID: String) throws {
        let escapedID = sql(threadID)
        let statementSQL = """
        begin immediate;
        delete from thread_dynamic_tools where thread_id = '\(escapedID)';
        delete from thread_spawn_edges where parent_thread_id = '\(escapedID)' or child_thread_id = '\(escapedID)';
        delete from threads where id = '\(escapedID)';
        commit;
        """
        _ = try Shell.run("/usr/bin/sqlite3", [stateDB.path, statementSQL])
        let remaining = try Shell.run(
            "/usr/bin/sqlite3",
            [stateDB.path, "select count(*) from threads where id = '\(escapedID)';"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard remaining == "0" else {
            throw WakeError.commandFailed("Thread metadata was not removed from the Codex state database.")
        }
    }

    private func loadSpawnEdgesReferencing(threadID: String) throws -> [ThreadSpawnEdgeRecord] {
        let database = try openReadOnly(stateDB)
        defer { sqlite3_close(database) }
        let query = """
        select parent_thread_id, child_thread_id, status
        from thread_spawn_edges
        where parent_thread_id = '\(sql(threadID))' or child_thread_id = '\(sql(threadID))';
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [ThreadSpawnEdgeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(ThreadSpawnEdgeRecord(
                parentThreadID: text(statement, 0),
                childThreadID: text(statement, 1),
                status: text(statement, 2)
            ))
        }
        return result
    }

    private func loadDynamicTools(threadID: String) throws -> [ThreadDynamicToolRecord] {
        let database = try openReadOnly(stateDB)
        defer { sqlite3_close(database) }
        let query = """
        select thread_id, position, name, description, input_schema, defer_loading, namespace
        from thread_dynamic_tools where thread_id = '\(sql(threadID))' order by position;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [ThreadDynamicToolRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(ThreadDynamicToolRecord(
                threadID: text(statement, 0),
                position: int64(statement, 1) ?? 0,
                name: text(statement, 2),
                description: text(statement, 3),
                inputSchema: text(statement, 4),
                deferLoading: int64(statement, 5) ?? 0,
                namespace: nullableText(statement, 6)
            ))
        }
        return result
    }

    private func restoreRelatedMetadata(
        spawnEdges: [ThreadSpawnEdgeRecord],
        dynamicTools: [ThreadDynamicToolRecord]
    ) throws {
        var statements: [String] = ["begin immediate;"]
        for tool in dynamicTools {
            statements.append("""
            insert or replace into thread_dynamic_tools
            (thread_id, position, name, description, input_schema, defer_loading, namespace)
            values (\(sqlValue(tool.threadID)), \(tool.position), \(sqlValue(tool.name)),
                    \(sqlValue(tool.description)), \(sqlValue(tool.inputSchema)),
                    \(tool.deferLoading), \(sqlValue(tool.namespace)));
            """)
        }
        for edge in spawnEdges {
            statements.append("""
            insert or replace into thread_spawn_edges (parent_thread_id, child_thread_id, status)
            values (\(sqlValue(edge.parentThreadID)), \(sqlValue(edge.childThreadID)), \(sqlValue(edge.status)));
            """)
        }
        statements.append("commit;")
        _ = try Shell.run("/usr/bin/sqlite3", [stateDB.path, statements.joined(separator: "\n")])
    }

    private func externalDatabaseSnapshots(threadID: String) throws -> [SQLiteDatabaseSnapshot] {
        let urls = [
            codexHome.appendingPathComponent("sqlite/codex-dev.db"),
            codexHome.appendingPathComponent("sqlite/codex-history-snapshots-dev.db")
        ]
        return try urls.compactMap { url in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try snapshotDatabase(url, threadID: threadID)
        }
    }

    private func backupExternalDatabases(
        _ snapshots: [SQLiteDatabaseSnapshot],
        stamp: String
    ) throws -> [String] {
        var backups: [String] = []
        for snapshot in snapshots where !snapshot.rows.isEmpty {
            let source = codexHome.appendingPathComponent(snapshot.relativePath)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = source.deletingLastPathComponent()
                .appendingPathComponent(source.lastPathComponent + ".codex-rescue-backup-" + stamp)
            if let saved = try? vacuumSnapshot(of: source, to: destination) {
                backups.append(saved.path)
            } else {
                backups.append(try backup(source, suffix: stamp).path)
            }
        }
        return backups
    }

    private func snapshotDatabase(_ url: URL, threadID: String) throws -> SQLiteDatabaseSnapshot {
        let database = try openReadOnly(url)
        defer { sqlite3_close(database) }
        var rows: [SQLiteRowSnapshot] = []

        for table in sqliteTables(database) {
            let columns = try sqliteColumns(database, table: table)
            let referenceColumns = ["thread_id", "parent_thread_id", "child_thread_id"]
                .filter(columns.contains)
            guard !referenceColumns.isEmpty else { continue }
            let whereClause = referenceColumns
                .map { "\(quotedIdentifier($0)) = ?" }
                .joined(separator: " or ")
            let query = "select * from \(quotedIdentifier(table)) where \(whereClause);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { throw sqliteError(database, context: "Cannot snapshot \(table)") }
            defer { sqlite3_finalize(statement) }
            for index in referenceColumns.indices {
                bindText(threadID, to: statement, index: Int32(index + 1))
            }
            let selectedColumns = (0..<sqlite3_column_count(statement)).map {
                String(cString: sqlite3_column_name(statement, $0))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let values = (0..<sqlite3_column_count(statement)).map {
                    sqliteValue(statement, index: $0)
                }
                rows.append(SQLiteRowSnapshot(table: table, columns: selectedColumns, values: values))
            }
        }

        let relativePath = String(url.path.dropFirst(codexHome.path.count + 1))
        return SQLiteDatabaseSnapshot(relativePath: relativePath, rows: rows)
    }

    private func deleteExternalDatabaseReferences(
        _ snapshots: [SQLiteDatabaseSnapshot],
        threadID: String
    ) throws {
        for snapshot in snapshots {
            let url = codexHome.appendingPathComponent(snapshot.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let database
            else {
                if let database { sqlite3_close(database) }
                throw WakeError.commandFailed("Cannot open \(snapshot.relativePath) for chat deletion.")
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(database, "begin immediate;", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError(database, context: "Cannot start chat deletion")
            }
            do {
                for table in sqliteTables(database) {
                    let columns = try sqliteColumns(database, table: table)
                    let referenceColumns = ["thread_id", "parent_thread_id", "child_thread_id"]
                        .filter(columns.contains)
                    guard !referenceColumns.isEmpty else { continue }
                    let whereClause = referenceColumns
                        .map { "\(quotedIdentifier($0)) = '\(sql(threadID))'" }
                        .joined(separator: " or ")
                    let statement = "delete from \(quotedIdentifier(table)) where \(whereClause);"
                    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                        throw sqliteError(database, context: "Cannot clean \(table)")
                    }
                }
                if snapshot.relativePath.hasSuffix("codex-dev.db") {
                    try bumpCatalogRevision(database)
                }
                guard sqlite3_exec(database, "commit;", nil, nil, nil) == SQLITE_OK else {
                    throw sqliteError(database, context: "Cannot commit chat deletion")
                }
            } catch {
                sqlite3_exec(database, "rollback;", nil, nil, nil)
                throw error
            }
        }
    }

    private func restoreExternalDatabaseSnapshots(_ snapshots: [SQLiteDatabaseSnapshot]) throws {
        for snapshot in snapshots where !snapshot.rows.isEmpty {
            let url = codexHome.appendingPathComponent(snapshot.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let database
            else {
                if let database { sqlite3_close(database) }
                throw WakeError.commandFailed("Cannot open \(snapshot.relativePath) for chat restore.")
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(database, "begin immediate;", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError(database, context: "Cannot start chat restore")
            }
            do {
                for row in snapshot.rows {
                    let columns = row.columns.map(quotedIdentifier).joined(separator: ", ")
                    let placeholders = Array(repeating: "?", count: row.values.count).joined(separator: ", ")
                    let query = "insert or replace into \(quotedIdentifier(row.table)) (\(columns)) values (\(placeholders));"
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                          let statement
                    else { throw sqliteError(database, context: "Cannot restore \(row.table)") }
                    defer { sqlite3_finalize(statement) }
                    for (index, value) in row.values.enumerated() {
                        bindSQLiteValue(value, to: statement, index: Int32(index + 1))
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw sqliteError(database, context: "Cannot restore \(row.table)")
                    }
                }
                if snapshot.relativePath.hasSuffix("codex-dev.db") {
                    try bumpCatalogRevision(database)
                }
                guard sqlite3_exec(database, "commit;", nil, nil, nil) == SQLITE_OK else {
                    throw sqliteError(database, context: "Cannot commit chat restore")
                }
            } catch {
                sqlite3_exec(database, "rollback;", nil, nil, nil)
                throw error
            }
        }
    }

    private func sqliteTables(_ database: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        let query = "select name from sqlite_master where type = 'table' and name not like 'sqlite_%';"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
        return result
    }

    private func bumpCatalogRevision(_ database: OpaquePointer) throws {
        guard sqliteTables(database).contains("local_thread_catalog_metadata") else { return }
        guard sqlite3_exec(
            database,
            "update local_thread_catalog_metadata set catalog_revision = catalog_revision + 1 where id = 1;",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw sqliteError(database, context: "Cannot refresh the Codex chat catalog")
        }
    }

    private func sqliteColumns(_ database: OpaquePointer, table: String) throws -> [String] {
        var statement: OpaquePointer?
        let query = "pragma table_info(\(quotedIdentifier(table)));"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw sqliteError(database, context: "Cannot inspect \(table)") }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 1)) }
        return result
    }

    private func sqliteValue(_ statement: OpaquePointer, index: Int32) -> SQLiteStoredValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: return .text(text(statement, index))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
        default: return .null
        }
    }

    private func bindSQLiteValue(_ value: SQLiteStoredValue, to statement: OpaquePointer, index: Int32) {
        switch value {
        case .null: sqlite3_bind_null(statement, index)
        case .integer(let value): sqlite3_bind_int64(statement, index, value)
        case .real(let value): sqlite3_bind_double(statement, index, value)
        case .text(let value): bindText(value, to: statement, index: index)
        case .blob(let data):
            data.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), sqliteTransient)
            }
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32) {
        value.withCString { pointer in
            _ = sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func sqliteError(_ database: OpaquePointer, context: String) -> WakeError {
        WakeError.commandFailed("\(context): \(String(cString: sqlite3_errmsg(database)))")
    }

    private func loadFullThreadRecord(threadID: String) throws -> ThreadSQLiteRecord {
        let query = """
        select id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
               sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
               git_sha, git_branch, git_origin_url, cli_version, first_user_message,
               agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
               created_at_ms, updated_at_ms, thread_source, preview,
               recency_at, recency_at_ms, history_mode, name, is_pinned,
               thread_section_id, section_position, section_entered_at_ms
        from threads
        where id = '\(sql(threadID))';
        """
        let database: OpaquePointer
        do {
            database = try openReadOnly(stateDB)
        } catch {
            database = try openReadOnlyImmutable(stateDB)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            let message = String(cString: sqlite3_errmsg(database))
            throw WakeError.commandFailed("Cannot prepare SQLite query: \(message)")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw WakeError.commandFailed("Thread metadata not found in Codex state database.")
        }

        return ThreadSQLiteRecord(
            id: text(statement, 0),
            rolloutPath: text(statement, 1),
            createdAt: int64(statement, 2) ?? 0,
            updatedAt: int64(statement, 3) ?? 0,
            source: text(statement, 4),
            modelProvider: text(statement, 5),
            cwd: text(statement, 6),
            title: text(statement, 7),
            sandboxPolicy: text(statement, 8),
            approvalMode: text(statement, 9),
            tokensUsed: int64(statement, 10) ?? 0,
            hasUserEvent: int64(statement, 11) ?? 0,
            archived: int64(statement, 12) ?? 0,
            archivedAt: int64(statement, 13),
            gitSHA: nullableText(statement, 14),
            gitBranch: nullableText(statement, 15),
            gitOriginURL: nullableText(statement, 16),
            cliVersion: text(statement, 17),
            firstUserMessage: text(statement, 18),
            agentNickname: nullableText(statement, 19),
            agentRole: nullableText(statement, 20),
            memoryMode: text(statement, 21),
            model: nullableText(statement, 22),
            reasoningEffort: nullableText(statement, 23),
            agentPath: nullableText(statement, 24),
            createdAtMs: int64(statement, 25),
            updatedAtMs: int64(statement, 26),
            threadSource: nullableText(statement, 27),
            preview: text(statement, 28),
            recencyAt: int64(statement, 29),
            recencyAtMs: int64(statement, 30),
            historyMode: nullableText(statement, 31),
            name: nullableText(statement, 32),
            isPinned: int64(statement, 33),
            threadSectionID: nullableText(statement, 34),
            sectionPosition: int64(statement, 35),
            sectionEnteredAtMs: int64(statement, 36)
        )
    }

    private func insertFullThreadRecord(_ record: ThreadSQLiteRecord) throws {
        let existing = try Shell.run(
            "/usr/bin/sqlite3",
            [stateDB.path, "select count(*) from threads where id = '\(sql(record.id))';"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing == "0" else {
            throw WakeError.commandFailed("Thread metadata already exists in Codex state database.")
        }

        let statementSQL = """
        insert into threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
            git_sha, git_branch, git_origin_url, cli_version, first_user_message,
            agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
            created_at_ms, updated_at_ms, thread_source, preview,
            recency_at, recency_at_ms, history_mode, name, is_pinned,
            thread_section_id, section_position, section_entered_at_ms
        ) values (
            \(sqlValue(record.id)),
            \(sqlValue(record.rolloutPath)),
            \(record.createdAt),
            \(record.updatedAt),
            \(sqlValue(record.source)),
            \(sqlValue(record.modelProvider)),
            \(sqlValue(record.cwd)),
            \(sqlValue(record.title)),
            \(sqlValue(record.sandboxPolicy)),
            \(sqlValue(record.approvalMode)),
            \(record.tokensUsed),
            \(record.hasUserEvent),
            \(record.archived),
            \(sqlValue(record.archivedAt)),
            \(sqlValue(record.gitSHA)),
            \(sqlValue(record.gitBranch)),
            \(sqlValue(record.gitOriginURL)),
            \(sqlValue(record.cliVersion)),
            \(sqlValue(record.firstUserMessage)),
            \(sqlValue(record.agentNickname)),
            \(sqlValue(record.agentRole)),
            \(sqlValue(record.memoryMode)),
            \(sqlValue(record.model)),
            \(sqlValue(record.reasoningEffort)),
            \(sqlValue(record.agentPath)),
            \(sqlValue(record.createdAtMs)),
            \(sqlValue(record.updatedAtMs)),
            \(sqlValue(record.threadSource)),
            \(sqlValue(record.preview)),
            \(sqlValue(record.recencyAt)),
            \(sqlValue(record.recencyAtMs)),
            \(sqlValue(record.historyMode)),
            \(sqlValue(record.name)),
            \(sqlValue(record.isPinned)),
            \(sqlValue(record.threadSectionID)),
            \(sqlValue(record.sectionPosition)),
            \(sqlValue(record.sectionEnteredAtMs))
        );
        """
        _ = try Shell.run("/usr/bin/sqlite3", [stateDB.path, statementSQL])
    }

    private func removeSessionIndexEntry(threadID: String) throws {
        guard fileManager.fileExists(atPath: sessionIndex.path) else { return }
        let text = try String(contentsOf: sessionIndex, encoding: .utf8)
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            guard let data = String(line).data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["id"] as? String == threadID
            else {
                lines.append(String(line))
                continue
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: sessionIndex, atomically: true, encoding: .utf8)
    }

    private func upsertSessionIndex(threadID: String, title: String, updatedAt: String) throws {
        guard fileManager.fileExists(atPath: sessionIndex.path) else { return }
        let text = try String(contentsOf: sessionIndex, encoding: .utf8)
        var lines: [String] = []
        var didUpdate = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            guard let data = String(line).data(using: .utf8),
                  var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                lines.append(String(line))
                continue
            }
            if obj["id"] as? String == threadID {
                obj["updated_at"] = updatedAt
                if (obj["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    obj["thread_name"] = title
                }
                let encoded = try JSONSerialization.data(withJSONObject: obj, options: [])
                lines.append(String(data: encoded, encoding: .utf8) ?? String(line))
                didUpdate = true
            } else {
                lines.append(String(line))
            }
        }

        if !didUpdate {
            let obj: [String: String] = [
                "id": threadID,
                "thread_name": title,
                "updated_at": updatedAt
            ]
            let encoded = try JSONSerialization.data(withJSONObject: obj, options: [])
            guard let line = String(data: encoded, encoding: .utf8) else {
                throw WakeError.invalidJSON("Cannot encode session index line")
            }
            lines.append(line)
        }

        try (lines.joined(separator: "\n") + "\n").write(to: sessionIndex, atomically: true, encoding: .utf8)
    }

    private func appendSessionIndex(threadID: String, title: String, updatedAt: String) throws {
        guard fileManager.fileExists(atPath: sessionIndex.path) else { return }
        let obj: [String: String] = [
            "id": threadID,
            "thread_name": title,
            "updated_at": updatedAt
        ]
        let encoded = try JSONSerialization.data(withJSONObject: obj, options: [])
        guard let line = String(data: encoded, encoding: .utf8) else {
            throw WakeError.invalidJSON("Cannot encode session index line")
        }
        let existing = try String(contentsOf: sessionIndex, encoding: .utf8)
        let separator = existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n"
        let handle = try FileHandle(forWritingTo: sessionIndex)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = (separator + line + "\n").data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private func appendSessionIndexEntry(_ entry: SessionIndexEntry) throws {
        guard fileManager.fileExists(atPath: sessionIndex.path) else { return }
        if try loadSessionIndex()[entry.id] != nil { return }
        var obj: [String: String] = ["id": entry.id]
        if let threadName = entry.thread_name {
            obj["thread_name"] = threadName
        }
        if let updatedAt = entry.updated_at {
            obj["updated_at"] = updatedAt
        }
        let encoded = try JSONSerialization.data(withJSONObject: obj, options: [])
        guard let line = String(data: encoded, encoding: .utf8) else {
            throw WakeError.invalidJSON("Cannot encode session index line")
        }
        let existing = try String(contentsOf: sessionIndex, encoding: .utf8)
        let separator = existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n"
        let handle = try FileHandle(forWritingTo: sessionIndex)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = (separator + line + "\n").data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private func updateSessionMeta(path: URL, timestamp: String) throws {
        let text = try String(contentsOf: path, encoding: .utf8)
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first,
              let data = String(first).data(using: .utf8),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WakeError.invalidJSON("Cannot decode first JSONL line") }

        obj["timestamp"] = timestamp
        var payload = obj["payload"] as? [String: Any] ?? [:]
        payload["timestamp"] = timestamp
        obj["payload"] = payload

        let encoded = try JSONSerialization.data(withJSONObject: obj, options: [])
        let firstLine = String(data: encoded, encoding: .utf8) ?? String(first)
        let rest = parts.count > 1 ? String(parts[1]) : ""
        try (firstLine + "\n" + rest).write(to: path, atomically: true, encoding: .utf8)
    }

    private func branchContent(from lines: [String], newThreadID: String, timestamp: String, cwd: String) throws -> String {
        guard let first = lines.first,
              let data = first.data(using: .utf8),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WakeError.invalidJSON("Cannot decode first JSONL line") }

        obj["timestamp"] = timestamp
        var payload = obj["payload"] as? [String: Any] ?? [:]
        payload["id"] = newThreadID
        payload["timestamp"] = timestamp
        payload["cwd"] = cwd
        payload["thread_source"] = "user"
        obj["payload"] = payload

        let encoded = try JSONSerialization.data(withJSONObject: obj, options: [])
        guard let firstLine = String(data: encoded, encoding: .utf8) else {
            throw WakeError.invalidJSON("Cannot encode branched session meta")
        }

        var result = [firstLine]
        result.append(contentsOf: lines.dropFirst())
        return result.joined(separator: "\n") + "\n"
    }

    private func insertBranchedSQLiteRow(
        sourceThreadID: String,
        newThreadID: String,
        rolloutPath: String,
        title: String,
        createdAt: Int64,
        updatedAt: Int64,
        createdAtMs: Int64,
        updatedAtMs: Int64
    ) throws {
        let sourceID = sql(sourceThreadID)
        let statementSQL = """
        insert into threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
            git_sha, git_branch, git_origin_url, cli_version, first_user_message,
            agent_nickname, agent_role, memory_mode, model, reasoning_effort, agent_path,
            created_at_ms, updated_at_ms, thread_source, preview
        )
        select
            '\(sql(newThreadID))',
            '\(sql(rolloutPath))',
            \(createdAt),
            \(updatedAt),
            source,
            model_provider,
            cwd,
            '\(sql(title))',
            sandbox_policy,
            approval_mode,
            0,
            has_user_event,
            0,
            NULL,
            git_sha,
            git_branch,
            git_origin_url,
            cli_version,
            first_user_message,
            agent_nickname,
            agent_role,
            memory_mode,
            model,
            reasoning_effort,
            agent_path,
            \(createdAtMs),
            \(updatedAtMs),
            'user',
            preview
        from threads
        where id = '\(sourceID)';
        """
        _ = try Shell.run("/usr/bin/sqlite3", [stateDB.path, statementSQL])
    }

    private func verifyBranchedSQLiteRow(threadID: String) throws {
        let output = try Shell.run(
            "/usr/bin/sqlite3",
            [stateDB.path, "select count(*) from threads where id = '\(sql(threadID))';"]
        )
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw WakeError.commandFailed("Branch was not registered in the Codex state database.")
        }
    }

    private func deleteBranchedSQLiteRow(threadID: String) throws {
        _ = try Shell.run(
            "/usr/bin/sqlite3",
            [stateDB.path, "delete from threads where id = '\(sql(threadID))';"]
        )
    }

    private func branchTitle(for thread: CodexThread) -> String {
        "Branch: \(thread.shortTitle)".prefixString(240)
    }

    private func branchDatePath(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    private func branchFileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: date)
    }

    private func uniqueThreadID() throws -> String {
        var id = makeUUIDv7()
        var attempts = 0
        while fileManager.fileExists(atPath: codexHome.appendingPathComponent("sessions").appendingPathComponent(id).path) {
            id = makeUUIDv7()
            attempts += 1
            if attempts > 10 {
                throw WakeError.commandFailed("Could not generate a unique thread id.")
            }
        }
        return id
    }

    private func makeUUIDv7() -> String {
        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = UInt8((timestampMs >> 40) & 0xff)
        bytes[1] = UInt8((timestampMs >> 32) & 0xff)
        bytes[2] = UInt8((timestampMs >> 24) & 0xff)
        bytes[3] = UInt8((timestampMs >> 16) & 0xff)
        bytes[4] = UInt8((timestampMs >> 8) & 0xff)
        bytes[5] = UInt8(timestampMs & 0xff)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-")
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func sqlValue(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(sql(value))'"
    }

    private func sqlValue(_ value: Int64?) -> String {
        guard let value else { return "NULL" }
        return "\(value)"
    }

    private func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct ThreadRow: Decodable {
    let id: String
    let rollout_path: String
    let created_at: Int64?
    let updated_at: Int64?
    let source: String
    let thread_source: String?
    let has_user_event: Int?
    let archived: Int?
    let title: String
    let first_user_message: String?
    let preview: String?
    let cwd: String
    let created_at_ms: Int64?
    let updated_at_ms: Int64?
    let model_provider: String
    let model: String?
    let reasoning_effort: String?
    let approval_mode: String
    let sandbox_policy: String
    let tokens_used: Int64?
    let archived_at: Int64?
    let git_sha: String?
    let git_branch: String?
    let git_origin_url: String?
    let agent_nickname: String?
    let agent_role: String?
    let agent_path: String?
    let recency_at: Int64?
    let recency_at_ms: Int64?
    let history_mode: String?
    let name: String?
    let is_pinned: Int64?
    let thread_section_id: String?
    let section_position: Int64?
    let section_entered_at_ms: Int64?
}

private struct ThreadSpawnEdgeRecord: Codable {
    let parentThreadID: String
    let childThreadID: String
    let status: String
}

private struct SessionIndexEntry: Codable {
    let id: String
    let thread_name: String?
    let updated_at: String?
}

private struct TrashedThreadManifest: Codable {
    let version: Int
    let threadID: String
    let title: String
    let originalPath: String
    let trashPath: String?
    let cwd: String
    let trashedAt: String
    let sqliteRecord: ThreadSQLiteRecord
    let sessionIndexEntry: SessionIndexEntry?
    let spawnEdges: [ThreadSpawnEdgeRecord]?
    let dynamicTools: [ThreadDynamicToolRecord]?
    let projectState: ThreadProjectState?
    let externalDatabases: [SQLiteDatabaseSnapshot]?
}

private struct ThreadSQLiteRecord: Codable {
    let id: String
    let rolloutPath: String
    let createdAt: Int64
    let updatedAt: Int64
    let source: String
    let modelProvider: String
    let cwd: String
    let title: String
    let sandboxPolicy: String
    let approvalMode: String
    let tokensUsed: Int64
    let hasUserEvent: Int64
    let archived: Int64
    let archivedAt: Int64?
    let gitSHA: String?
    let gitBranch: String?
    let gitOriginURL: String?
    let cliVersion: String
    let firstUserMessage: String
    let agentNickname: String?
    let agentRole: String?
    let memoryMode: String
    let model: String?
    let reasoningEffort: String?
    let agentPath: String?
    let createdAtMs: Int64?
    let updatedAtMs: Int64?
    let threadSource: String?
    let preview: String
    let recencyAt: Int64?
    let recencyAtMs: Int64?
    let historyMode: String?
    let name: String?
    let isPinned: Int64?
    let threadSectionID: String?
    let sectionPosition: Int64?
    let sectionEnteredAtMs: Int64?
}

private struct ThreadDynamicToolRecord: Codable {
    let threadID: String
    let position: Int64
    let name: String
    let description: String
    let inputSchema: String
    let deferLoading: Int64
    let namespace: String?
}

private struct ThreadProjectState: Codable {
    let projectID: String?
    let sidebarProjectID: String?
    let sidebarPosition: Int?
    let wasProjectless: Bool
    let workspaceRootHint: String?
    let outputDirectory: String?
}

private struct SQLiteDatabaseSnapshot: Codable {
    let relativePath: String
    let rows: [SQLiteRowSnapshot]
}

private struct SQLiteRowSnapshot: Codable {
    let table: String
    let columns: [String]
    let values: [SQLiteStoredValue]
}

private enum SQLiteStoredValue: Codable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}
