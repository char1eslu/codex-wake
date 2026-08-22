import Foundation

package final class ClaudeStore: ThreadStore, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let claudeHome: URL
    private let projectsRoot: URL
    private let backupTrash: URL
    private let threadTrash: URL

    package init(claudeHome: URL? = nil) {
        let home = claudeHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.claudeHome = home
        self.projectsRoot = home.appendingPathComponent("projects", isDirectory: true)
        self.backupTrash = home.appendingPathComponent(".claude-keeper-trash", isDirectory: true)
        self.threadTrash = backupTrash.appendingPathComponent("threads", isDirectory: true)
    }

    // MARK: - Browsing

    package func loadActiveStateRoot() throws -> ActiveStateRoot? {
        nil
    }

    package func loadThreads() throws -> [CodexThread] {
        guard fileManager.fileExists(atPath: projectsRoot.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var threads: [CodexThread] = []
        for dir in projectDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: keys,
                options: []
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let thread = makeThread(from: file)
                else { continue }
                threads.append(thread)
            }
        }
        return threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func makeThread(from url: URL) -> CodexThread? {
        let sessionID = url.deletingPathExtension().lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let updatedAt = values?.contentModificationDate ?? .distantPast

        var cwd = decodedProjectPath(from: url.deletingLastPathComponent().lastPathComponent)
        var createdAt: Date?
        var customTitle: String?
        var firstUserMessage = ""
        var preview = ""
        var hasUserMessage = false

        let maxScanBytes = 4 * 1024 * 1024
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var scanned = 0
        while scanned < maxScanBytes {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            scanned += chunk.count
            guard let text = String(data: chunk, encoding: .utf8) else { break }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(line).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if createdAt == nil, let ts = obj["timestamp"] as? String {
                    createdAt = WakeDates.parseISO(ts)
                }
                if let storedCwd = obj["cwd"] as? String, !storedCwd.isEmpty {
                    cwd = storedCwd
                }
                if customTitle == nil, let title = obj["customTitle"] as? String, !title.isEmpty {
                    customTitle = title
                }
                if !hasUserMessage, obj["type"] as? String == "user",
                   obj["isSidechain"] as? Bool != true,
                   let text = extractContentText(obj["message"]).trimmedNonEmpty {
                    firstUserMessage = text
                    preview = text
                    hasUserMessage = true
                }
                if createdAt != nil && customTitle != nil && hasUserMessage {
                    break
                }
            }
            if createdAt != nil && customTitle != nil && hasUserMessage {
                break
            }
        }

        guard hasUserMessage || customTitle != nil else { return nil }

        return CodexThread(
            id: sessionID,
            rolloutPath: url.path,
            createdAt: createdAt ?? updatedAt,
            updatedAt: updatedAt,
            createdAtMs: nil,
            updatedAtMs: nil,
            source: "claude",
            threadSource: "claude",
            parentThreadID: nil,
            spawnStatus: nil,
            childThreadCount: 0,
            hasUserEvent: hasUserMessage,
            archived: false,
            title: customTitle ?? "",
            sessionIndexTitle: "",
            firstUserMessage: firstUserMessage,
            preview: preview,
            cwd: cwd,
            isInSessionIndex: true,
            sessionIndexUpdatedAt: nil,
            sessionMetaTimestamp: nil,
            sessionPayloadTimestamp: nil,
            fileExists: true
        )
    }

    private func decodedProjectPath(from encodedDirName: String) -> String {
        "/" + encodedDirName
    }

    static func encodedProjectDirectoryName(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Preview

    package func loadPreview(for thread: CodexThread) throws -> ThreadPreview {
        guard fileManager.fileExists(atPath: thread.rolloutPath) else {
            throw WakeError.missingThreadFile(thread.rolloutPath)
        }
        let content = try String(contentsOf: thread.rolloutURL, encoding: .utf8)
        var messages: [PreviewMessage] = []
        var visibleUserMessageCount = 0
        var previousRoleWasUser = false

        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = obj["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            guard obj["isSidechain"] as? Bool != true else { continue }

            let role = type == "user" ? "user" : "assistant"
            let text = extractContentText(obj["message"])
            guard let visibleText = text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { continue }

            let lineNumber = index + 1
            let isTurnStart = role == "user" && !previousRoleWasUser
            messages.append(
                PreviewMessage(
                    role: role,
                    text: visibleText.oneLine.prefixString(4000),
                    timestamp: obj["timestamp"] as? String,
                    lineNumber: lineNumber,
                    branchLineNumber: isTurnStart ? lineNumber : nil,
                    isTurnStart: isTurnStart,
                    isSteered: role == "user" && !isTurnStart,
                    isFirstVisibleUserMessage: role == "user" && visibleUserMessageCount == 0
                )
            )
            if role == "user" {
                visibleUserMessageCount += 1
            }
            previousRoleWasUser = role == "user"
        }

        return ThreadPreview(threadID: thread.id, messages: messages, rawError: nil)
    }

    package func threadContainsRawText(_ thread: CodexThread, query: String) throws -> Bool {
        guard fileManager.fileExists(atPath: thread.rolloutPath) else { return false }
        guard query.count >= 3 else { return false }
        let content = try String(contentsOf: thread.rolloutURL, encoding: .utf8)
        return content.lowercased().contains(query.lowercased())
    }

    private func extractContentText(_ message: Any?) -> String {
        guard let message = message as? [String: Any] else { return "" }
        switch message["content"] {
        case let text as String:
            return text
        case let blocks as [[String: Any]]:
            var parts: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { parts.append(text) }
                case "thinking":
                    if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                        parts.append("[thinking] \(thinking)")
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    parts.append("[tool: \(name)]")
                default:
                    break
                }
            }
            return parts.joined(separator: "\n")
        default:
            return ""
        }
    }

    // MARK: - Move between projects

    package func move(thread: CodexThread, to project: ProjectSummary) throws -> MoveReport {
        guard !project.path.isEmpty else {
            throw WakeError.commandFailed("Cannot move to All Projects")
        }
        guard fileManager.fileExists(atPath: thread.rolloutPath) else {
            throw WakeError.missingThreadFile(thread.rolloutPath)
        }

        let stamp = Self.backupStamp()
        let backupSuffix = "\(stamp)-move"
        var backups: [String] = []
        var changed: [String] = []

        backups.append(try backup(thread.rolloutURL, suffix: backupSuffix).path)

        let original = try Data(contentsOf: thread.rolloutURL)
        let moved = try Self.rewritingCWD(original, from: thread.cwd, to: project.path)

        let destinationDirectory = projectsRoot.appendingPathComponent(
            Self.encodedProjectDirectoryName(for: project.path),
            isDirectory: true
        )
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(thread.rolloutURL.lastPathComponent)

        do {
            try writeDataAtomically(moved, to: destination)
            changed.append(destination.path)
            try fileManager.removeItem(at: thread.rolloutURL)
            changed.append(thread.rolloutPath)
        } catch {
            try? fileManager.removeItem(at: destination)
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

    static func rewritingCWD(_ data: Data, from oldPath: String, to newPath: String) throws -> Data {
        guard let content = String(data: data, encoding: .utf8) else {
            throw WakeError.commandFailed("Session file is not valid UTF-8.")
        }
        var outputLines: [String] = []
        outputLines.reserveCapacity(content.split(separator: "\n", omittingEmptySubsequences: true).count)
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                outputLines.append(String(line))
                continue
            }
            if (obj["cwd"] as? String) == oldPath {
                obj["cwd"] = newPath
            }
            guard let rewritten = try? JSONSerialization.data(withJSONObject: obj),
                  let rewrittenLine = String(data: rewritten, encoding: .utf8)
            else {
                outputLines.append(String(line))
                continue
            }
            outputLines.append(rewrittenLine)
        }
        return Data(outputLines.joined(separator: "\n").appending("\n").utf8)
    }

    // MARK: - Trash

    package func moveThreadToTrash(_ thread: CodexThread) throws -> TrashThreadReport {
        let rolloutURL = thread.rolloutURL.standardizedFileURL
        guard rolloutURL.path.hasPrefix(projectsRoot.standardizedFileURL.path + "/") else {
            throw WakeError.commandFailed("Refusing to trash a chat file outside ~/.claude/projects.")
        }
        let stamp = Self.backupStamp()
        var backups: [String] = []
        var changed: [String] = []

        let trashDirectory = threadTrash.appendingPathComponent(thread.id, isDirectory: true)
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        var trashedPath: String?
        if fileManager.fileExists(atPath: rolloutURL.path) {
            backups.append(try backup(rolloutURL, suffix: "\(stamp)-trash-thread").path)
            let destination = uniqueTrashURL(for: rolloutURL.lastPathComponent, in: trashDirectory)
            try fileManager.moveItem(at: rolloutURL, to: destination)
            trashedPath = destination.path
            changed.append(thread.rolloutPath)
        }

        let manifest = ClaudeTrashManifest(
            version: 1,
            threadID: thread.id,
            title: thread.shortTitle,
            originalPath: thread.rolloutPath,
            trashPath: trashedPath,
            cwd: thread.cwd,
            trashedAt: WakeDates.isoNowForJSONL()
        )
        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try writeDataAtomically(manifestData, to: trashDirectory.appendingPathComponent("manifest.json"))

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

    package func loadThreadTrash() throws -> [TrashedThread] {
        guard fileManager.fileExists(atPath: threadTrash.path) else { return [] }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: threadTrash,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return [] }

        var threads: [TrashedThread] = []
        for entry in entries {
            let manifestURL = entry.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let manifest = try? JSONDecoder().decode(ClaudeTrashManifest.self, from: Data(contentsOf: manifestURL))
            else { continue }
            let trashSize: Int64 = manifest.trashPath.flatMap { path -> Int64? in
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
                return values.flatMap { Int64($0.fileSize ?? 0) }
            } ?? 0
            threads.append(
                TrashedThread(
                    threadID: manifest.threadID,
                    title: manifest.title,
                    originalPath: manifest.originalPath,
                    trashPath: manifest.trashPath,
                    manifestPath: manifestURL.path,
                    cwd: manifest.cwd,
                    trashedAt: WakeDates.parseISO(manifest.trashedAt),
                    size: trashSize,
                    originalExists: fileManager.fileExists(atPath: manifest.originalPath)
                )
            )
        }
        return threads.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    package func restoreTrashedThread(_ thread: TrashedThread) throws {
        let manifestURL = URL(fileURLWithPath: thread.manifestPath)
        let manifest = try JSONDecoder().decode(ClaudeTrashManifest.self, from: Data(contentsOf: manifestURL))
        guard let trashPath = manifest.trashPath else {
            throw WakeError.commandFailed("This chat had no session file to restore.")
        }
        let originalURL = URL(fileURLWithPath: manifest.originalPath)
        if fileManager.fileExists(atPath: originalURL.path) {
            throw WakeError.commandFailed("A chat file already exists at the original location.")
        }
        try fileManager.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: URL(fileURLWithPath: trashPath), to: originalURL)
        try fileManager.removeItem(at: manifestURL.deletingLastPathComponent())
    }

    package func deleteTrashedThreadPermanently(_ thread: TrashedThread) throws {
        let directory = URL(fileURLWithPath: thread.manifestPath).deletingLastPathComponent()
        try fileManager.removeItem(at: directory)
    }

    package func emptyThreadTrash() throws -> Int {
        let count = (try? loadThreadTrash())?.count ?? 0
        if fileManager.fileExists(atPath: threadTrash.path) {
            try fileManager.removeItem(at: threadTrash)
        }
        return count
    }

    // MARK: - Backups

    package func loadBackups() throws -> [BackupFile] {
        try scanBackups(in: claudeHome, includeTrash: false)
    }

    package func loadBackupTrash() throws -> [BackupFile] {
        guard fileManager.fileExists(atPath: backupTrash.path) else { return [] }
        return try scanBackups(in: backupTrash, includeTrash: true)
    }

    private func scanBackups(in root: URL, includeTrash: Bool) throws -> [BackupFile] {
        let marker = ".claude-rescue-backup-"
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = includeTrash
            ? [.skipsPackageDescendants]
            : [.skipsPackageDescendants, .skipsHiddenFiles]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            return []
        }

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
                let relativeDirectory = String(directoryURL.path.dropFirst(backupTrash.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                originalDirectoryURL = relativeDirectory.isEmpty
                    ? claudeHome
                    : claudeHome.appendingPathComponent(relativeDirectory, isDirectory: true)
            } else {
                originalDirectoryURL = directoryURL
            }
            let originalURL = originalDirectoryURL.appendingPathComponent(originalName)
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
                    kind: originalName.hasSuffix(".jsonl") ? .chatFile : .other,
                    originalExists: fileManager.fileExists(atPath: originalURL.path),
                    chatTitle: nil,
                    reason: backupReason(for: stamp)
                )
            )
        }
        return backups.sorted { ($0.createdAt ?? $0.modifiedAt ?? .distantPast) > ($1.createdAt ?? $1.modifiedAt ?? .distantPast) }
    }

    private func backupReason(for stamp: String) -> String {
        if stamp.hasSuffix("-move") { return "Created before moving a chat" }
        if stamp.hasSuffix("-trash-thread") { return "Created before trashing a chat" }
        return "Safety backup"
    }

    package func moveBackupToTrash(_ backup: BackupFile) throws {
        let source = URL(fileURLWithPath: backup.backupPath).standardizedFileURL
        guard source.path.hasPrefix(claudeHome.standardizedFileURL.path + "/"),
              source.lastPathComponent.contains(".claude-rescue-backup-")
        else {
            throw WakeError.commandFailed("Refusing to move non-Claude Keeper backup file")
        }
        let sourceDirectory = source.deletingLastPathComponent()
        let relativeDirectory = String(sourceDirectory.path.dropFirst(claudeHome.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let destinationDirectory = relativeDirectory.isEmpty
            ? backupTrash
            : backupTrash.appendingPathComponent(relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: uniqueTrashURL(for: source.lastPathComponent, in: destinationDirectory))
    }

    package func restoreBackup(_ backupFile: BackupFile) throws {
        let backupURL = URL(fileURLWithPath: backupFile.backupPath).standardizedFileURL
        let originalURL = URL(fileURLWithPath: backupFile.originalPath).standardizedFileURL
        guard backupURL.path.hasPrefix(claudeHome.standardizedFileURL.path + "/"),
              backupURL.lastPathComponent.contains(".claude-rescue-backup-")
        else {
            throw WakeError.commandFailed("Refusing to restore non-Claude Keeper backup file.")
        }
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw WakeError.commandFailed("Backup file is missing.")
        }
        if fileManager.fileExists(atPath: originalURL.path) {
            try fileManager.removeItem(at: originalURL)
        }
        try fileManager.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: backupURL, to: originalURL)
    }

    package func emptyBackupTrash() throws -> Int {
        guard fileManager.fileExists(atPath: backupTrash.path) else { return 0 }
        let count = (try? loadBackupTrash())?.count ?? 0
        try fileManager.removeItem(at: backupTrash)
        return count
    }

    // MARK: - Unsupported Codex operations

    package func wake(thread: CodexThread) throws -> WakeReport {
        throw WakeError.unsupportedByClaudeStore("Repair Index")
    }

    package func trim(thread: CodexThread, fromLine lineNumber: Int) throws -> TrimReport {
        throw WakeError.unsupportedByClaudeStore("Trim")
    }

    package func branch(thread: CodexThread, fromLine lineNumber: Int) throws -> BranchReport {
        throw WakeError.unsupportedByClaudeStore("Branch")
    }

    // MARK: - Helpers

    private func backup(_ url: URL, suffix: String) throws -> URL {
        let stamped = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(suffix).claude-rescue-backup-\(suffix)")
        try fileManager.copyItem(at: url, to: stamped)
        return stamped
    }

    private func uniqueTrashURL(for fileName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(fileName)-\(counter)")
            counter += 1
        }
        return candidate
    }

    private func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct ClaudeTrashManifest: Codable {
    let version: Int
    let threadID: String
    let title: String
    let originalPath: String
    let trashPath: String?
    let cwd: String
    let trashedAt: String
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
