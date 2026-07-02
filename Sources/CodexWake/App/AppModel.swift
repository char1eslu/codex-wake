import Foundation
import AppKit
import CodexKeeperCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var isLoading = false
    @Published var status = "Ready"
    @Published var errorMessage: String?
    @Published var searchText = "" {
        didSet { applyFilters() }
    }
    @Published var isDeepSearching = false
    @Published var selectedProjectID = ProjectSummary.allID {
        didSet { applyFilters() }
    }
    @Published var selectedThreadID: String?
    @Published var selectedThreadIDs: Set<String> = []
    @Published var selectedBackupIDs: Set<String> = []
    @Published var selectedTrashThreadIDs: Set<String> = []
    @Published var selectedTrashBackupIDs: Set<String> = []
    @Published private(set) var projects: [ProjectSummary] = [.all]
    @Published private(set) var threads: [CodexThread] = []
    @Published private(set) var filteredThreads: [CodexThread] = []
    @Published private(set) var backups: [BackupFile] = []
    @Published private(set) var backupTrash: [BackupFile] = []
    @Published private(set) var threadTrash: [TrashedThread] = []
    @Published private(set) var isLoadingBackups = false
    @Published var preview: ThreadPreview?
    @Published private(set) var isPreviewLoading = false
    @Published var operationReport: OperationReport?
    @Published private(set) var isDemoMode: Bool
    @Published private(set) var isInstallingCommandLineTool = false
    @Published private(set) var isUninstallingCommandLineTool = false

    private let store: any ThreadStore
    private var deepSearchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewDebounceTask: Task<Void, Never>?
    private var previewCache: [String: ThreadPreview] = [:]
    private var previewCacheOrder: [String] = []
    private let previewCacheLimit = 80
    private let keyboardPreviewDelayNanoseconds: UInt64 = 180_000_000

    var selectedThread: CodexThread? {
        threads.first { $0.id == selectedThreadID }
    }

    var selectedThreads: [CodexThread] {
        orderedThreads(for: selectedThreadIDs)
    }

    var selectedThreadCount: Int {
        selectedThreadIDs.count
    }

    var canOperateOnSelectedThreads: Bool {
        selectedThreads.contains { !$0.archived && $0.fileExists }
    }

    var canRepairSelectedThreads: Bool {
        selectedThreads.contains(where: \.needsRepair)
    }

    var canTrashSelectedThreads: Bool {
        !selectedThreads.isEmpty
    }

    var moveTargetProjects: [ProjectSummary] {
        let movableThreads = selectedThreads.filter { !$0.archived && $0.fileExists }
        guard !movableThreads.isEmpty else { return [] }
        return projects.filter { project in
            project.id != ProjectSummary.allID && project.id != ProjectSummary.chatsID && !movableThreads.allSatisfy { $0.cwd == project.path }
        }
    }

    var selectedOperationReport: OperationReport? {
        guard let selectedThreadID,
              let report = operationReport,
              report.threadIDs.contains(selectedThreadID)
        else { return nil }
        return report
    }

    var totalBackupSize: Int64 {
        backups.reduce(0) { $0 + $1.size }
    }

    var selectedBackupSize: Int64 {
        selectedBackups.reduce(0) { $0 + $1.size }
    }

    var backupSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalBackupSize, countStyle: .file)
    }

    var selectedBackupSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: selectedBackupSize, countStyle: .file)
    }

    var selectedBackups: [BackupFile] {
        let ids = selectedBackupIDs
        return backups.filter { ids.contains($0.id) }
    }

    var selectedTrashThreads: [TrashedThread] {
        let ids = selectedTrashThreadIDs
        return threadTrash.filter { ids.contains($0.id) }
    }

    var selectedTrashBackups: [BackupFile] {
        let ids = selectedTrashBackupIDs
        return backupTrash.filter { ids.contains($0.id) }
    }

    var trashItemCount: Int {
        threadTrash.count + backupTrash.count
    }

    var trashSize: Int64 {
        threadTrash.reduce(0) { $0 + $1.size } + backupTrash.reduce(0) { $0 + $1.size }
    }

    var trashSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: trashSize, countStyle: .file)
    }

    init(demoMode: Bool = AppModel.detectDemoMode(), store: (any ThreadStore)? = nil) {
        self.isDemoMode = demoMode
        self.store = store ?? (demoMode ? DemoCodexStore() : CodexStore())
        Task { [weak self] in await self?.refresh() }
    }

    deinit {
        deepSearchTask?.cancel()
        previewTask?.cancel()
        previewDebounceTask?.cancel()
    }

    func refresh() async {
        isLoading = true
        status = isDemoMode ? "Loading demo chats..." : "Scanning ~/.codex..."
        errorMessage = nil
        defer { isLoading = false }

        do {
            let store = self.store
            let loaded = try await Task.detached(priority: .userInitiated) {
                try store.loadThreads()
            }.value
            threads = loaded
            projects = ProjectSummary.make(from: loaded)
            if selectedThreadIDs.isEmpty, let first = loaded.first {
                selectedThreadIDs = [first.id]
                selectedThreadID = first.id
            }
            applyFilters()
            status = isDemoMode ? "Loaded \(loaded.count) demo chats" : "Loaded \(loaded.count) chats"
            if let selectedThreadID {
                startPreviewLoad(threadID: selectedThreadID)
            } else {
                cancelPreviewLoad(clearPreview: true)
            }
        } catch {
            errorMessage = Self.readable(error)
            status = "Error"
        }
    }

    func installCommandLineTool() async {
        guard !isInstallingCommandLineTool else { return }
        isInstallingCommandLineTool = true
        status = "Installing CLI..."
        errorMessage = nil
        defer { isInstallingCommandLineTool = false }

        do {
            let result = try CommandLineToolInstaller.installBundledCLI()
            status = "Installed CLI"
            showCommandLineToolInstallAlert(result)
        } catch {
            let message = Self.readable(error)
            errorMessage = message
            status = "CLI install failed"
            showCommandLineToolInstallError(message)
        }
    }

    func uninstallCommandLineTool() async {
        guard !isUninstallingCommandLineTool else { return }
        isUninstallingCommandLineTool = true
        status = "Uninstalling CLI..."
        errorMessage = nil
        defer { isUninstallingCommandLineTool = false }

        do {
            let result = try CommandLineToolInstaller.uninstallCLI()
            status = result.didRemove ? "Uninstalled CLI" : "CLI was not installed"
            showCommandLineToolUninstallAlert(result)
        } catch {
            let message = Self.readable(error)
            errorMessage = message
            status = "CLI uninstall failed"
            showCommandLineToolUninstallError(message)
        }
    }

    func updateThreadSelection(_ ids: Set<String>, preferredID: String? = nil) {
        setSelection(ids, preferredID: preferredID, shouldLoadPreview: true)
    }

    func selectThread(_ thread: CodexThread) {
        setSelection([thread.id], preferredID: thread.id, shouldLoadPreview: true)
    }

    func focusContextSelection(on thread: CodexThread) {
        if selectedThreadIDs.contains(thread.id) {
            setSelection(selectedThreadIDs, preferredID: thread.id, shouldLoadPreview: true)
        } else {
            selectThread(thread)
        }
    }

    func loadPreview(threadID: String) async {
        previewDebounceTask?.cancel()
        previewDebounceTask = nil
        previewTask?.cancel()
        previewTask = nil
        await loadPreviewNow(threadID: threadID)
    }

    private func startPreviewLoad(threadID: String, delayNanoseconds: UInt64 = 0) {
        previewDebounceTask?.cancel()
        previewDebounceTask = nil
        previewTask?.cancel()
        previewTask = nil

        guard delayNanoseconds > 0 else {
            previewTask = Task { [weak self] in
                await self?.loadPreviewNow(threadID: threadID)
            }
            return
        }

        previewDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.loadPreviewNow(threadID: threadID)
            guard !Task.isCancelled else { return }
            self?.clearPreviewDebounceTask()
        }
    }

    private func clearPreviewDebounceTask() {
        previewDebounceTask = nil
    }

    private func startKeyboardPreviewLoad(threadID: String) {
        startPreviewLoad(threadID: threadID, delayNanoseconds: keyboardPreviewDelayNanoseconds)
    }

    private func loadPreviewNow(threadID: String) async {
        guard let thread = threads.first(where: { $0.id == threadID }) else {
            cancelPreviewLoad(clearPreview: true)
            return
        }
        if let cached = cachedPreview(for: threadID) {
            preview = cached
            isPreviewLoading = false
            return
        }

        preview = nil
        isPreviewLoading = true
        do {
            let store = self.store
            let loadedPreview = try await Task.detached(priority: .userInitiated) {
                try store.loadPreview(for: thread)
            }.value
            guard !Task.isCancelled, selectedThreadID == threadID else { return }
            cachePreview(loadedPreview)
            preview = loadedPreview
            isPreviewLoading = false
        } catch {
            guard !Task.isCancelled, selectedThreadID == threadID else { return }
            preview = ThreadPreview(threadID: thread.id, messages: [], rawError: Self.readable(error))
            isPreviewLoading = false
        }
    }

    func wakeSelectedThread() async {
        await wakeSelectedThreads()
    }

    func wakeSelectedThreads() async {
        await wakeThreads(ids: selectedThreadIDs)
    }

    func wakeThreads(ids: Set<String>) async {
        let selected = orderedThreads(for: ids)
        let targets = selected.filter(\.needsRepair)
        guard !targets.isEmpty else {
            status = "No selected chats need index repair"
            return
        }

        isLoading = true
        status = targets.count == 1 ? "Repairing index..." : "Repairing index for \(targets.count) chats..."
        errorMessage = nil
        operationReport = nil
        defer { isLoading = false }

        let store = self.store
        let result = await Self.runThreadBatch(targets: targets) { thread in
            let report = try store.wake(thread: thread)
            return (backups: report.backups, changedFiles: report.changedFiles)
        }

        operationReport = OperationReport(
            title: "Repair Index complete",
            threadIDs: result.targetIDs,
            timestamp: WakeDates.display(Date()),
            summary: "\(result.successIDs.count) of \(targets.count) missing index entries repaired",
            backups: result.backups,
            changedFiles: Array(Set(result.changedFiles)).sorted(),
            failures: result.failures
        )
        status = result.failures.isEmpty ? "Repair Index complete" : "Repair Index completed with \(result.failures.count) failures"

        invalidatePreviewCache(for: result.successIDs)
        let idsToKeep = ids
        await refresh()
        setSelection(idsToKeep, shouldLoadPreview: true)
    }

    func moveSelectedThread(to project: ProjectSummary) async {
        await moveSelectedThreads(to: project)
    }

    func moveSelectedThreads(to project: ProjectSummary) async {
        let targets = orderedThreads(for: selectedThreadIDs).filter {
            !$0.archived && $0.fileExists && $0.cwd != project.path
        }
        guard !targets.isEmpty else {
            status = "No selected chats need to move"
            return
        }

        isLoading = true
        status = targets.count == 1 ? "Moving chat..." : "Moving \(targets.count) chats..."
        errorMessage = nil
        operationReport = nil
        defer { isLoading = false }

        let store = self.store
        let result = await Self.runThreadBatch(targets: targets) { thread in
            let report = try store.move(thread: thread, to: project)
            return (backups: report.backups, changedFiles: report.changedFiles)
        }

        operationReport = OperationReport(
            title: "Move complete",
            threadIDs: result.targetIDs,
            timestamp: WakeDates.display(Date()),
            summary: "\(result.successIDs.count) of \(targets.count) chats moved to \(project.name)",
            backups: result.backups,
            changedFiles: Array(Set(result.changedFiles)).sorted(),
            failures: result.failures
        )
        status = result.failures.isEmpty ? "Moved to \(project.name)" : "Move completed with \(result.failures.count) failures"

        invalidatePreviewCache(for: result.successIDs)
        await refresh()
        selectedProjectID = project.id
        setSelection(result.successIDs.isEmpty ? Set(targets.map(\.id)) : result.successIDs, shouldLoadPreview: true)
    }

    func moveSelectedThreadsToTrash() async {
        await moveThreadsToTrash(ids: selectedThreadIDs)
    }

    func moveThreadsToTrash(ids: Set<String>) async {
        let targets = orderedThreads(for: ids)
        guard !targets.isEmpty else { return }

        isLoading = true
        status = targets.count == 1 ? "Moving chat to Trash..." : "Moving \(targets.count) chats to Trash..."
        errorMessage = nil
        operationReport = nil
        defer { isLoading = false }

        let store = self.store
        let result = await Self.runThreadBatch(targets: targets) { thread in
            let report = try store.moveThreadToTrash(thread)
            return (backups: report.backups, changedFiles: report.changedFiles)
        }

        operationReport = OperationReport(
            title: "Move to Trash complete",
            threadIDs: result.targetIDs,
            timestamp: WakeDates.display(Date()),
            summary: "\(result.successIDs.count) of \(targets.count) chats moved to Codex Keeper Trash",
            backups: result.backups,
            changedFiles: Array(Set(result.changedFiles)).sorted(),
            failures: result.failures
        )
        status = result.failures.isEmpty ? "Moved to Trash" : "Move to Trash completed with \(result.failures.count) failures"

        invalidatePreviewCache(for: result.successIDs)
        await refresh()
        await refreshBackups()
    }

    private nonisolated static func runThreadBatch(
        targets: [CodexThread],
        operation: @escaping @Sendable (CodexThread) throws -> (backups: [String], changedFiles: [String])
    ) async -> BatchOperationResult {
        await Task.detached(priority: .userInitiated) {
            var backups: [String] = []
            var changedFiles: [String] = []
            var failures: [String] = []
            var successIDs: Set<String> = []

            for thread in targets {
                do {
                    let files = try operation(thread)
                    backups.append(contentsOf: files.backups)
                    changedFiles.append(contentsOf: files.changedFiles)
                    successIDs.insert(thread.id)
                } catch {
                    failures.append("\(thread.shortTitle): \(Self.readable(error))")
                }
            }

            return BatchOperationResult(
                targetIDs: Set(targets.map(\.id)),
                successIDs: successIDs,
                backups: backups,
                changedFiles: changedFiles,
                failures: failures
            )
        }.value
    }

    func revealSelectedInFinder() {
        revealThreadsInFinder(ids: selectedThreadIDs)
    }

    func revealThreadsInFinder(ids: Set<String>) {
        guard !isDemoMode else {
            status = "Demo mode has no local files"
            return
        }
        let urls = orderedThreads(for: ids)
            .filter(\.fileExists)
            .map(\.rolloutURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectedPath() {
        copyThreadPaths(ids: selectedThreadIDs)
    }

    func copyThreadPaths(ids: Set<String>) {
        guard !isDemoMode else {
            status = "Demo mode has no local paths"
            return
        }
        let paths = orderedThreads(for: ids).map(\.rolloutPath)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        status = paths.count == 1 ? "Path copied" : "\(paths.count) paths copied"
    }

    func refreshBackups() async {
        isLoadingBackups = true
        errorMessage = nil
        defer { isLoadingBackups = false }

        do {
            let store = self.store
            let loaded = try await Task.detached(priority: .userInitiated) {
                (
                    backups: try store.loadBackups(),
                    backupTrash: try store.loadBackupTrash(),
                    threadTrash: try store.loadThreadTrash()
                )
            }.value
            backups = loaded.backups
            backupTrash = loaded.backupTrash
            threadTrash = loaded.threadTrash
            selectedBackupIDs = selectedBackupIDs.intersection(Set(loaded.backups.map(\.id)))
            selectedTrashBackupIDs = selectedTrashBackupIDs.intersection(Set(loaded.backupTrash.map(\.id)))
            selectedTrashThreadIDs = selectedTrashThreadIDs.intersection(Set(loaded.threadTrash.map(\.id)))
            status = loaded.backups.isEmpty ? "No backups found" : "Found \(loaded.backups.count) backups"
        } catch {
            errorMessage = Self.readable(error)
            status = "Backup scan failed"
        }
    }

    func deleteSelectedBackups() async {
        await moveBackupsToTrash(ids: selectedBackupIDs)
    }

    func deleteAllBackups() async {
        await moveBackupsToTrash(ids: Set(backups.map(\.id)))
    }

    func deleteBackups(paths: Set<String>) async {
        await moveBackupsToTrash(ids: paths)
    }

    func moveBackupsToTrash(ids: Set<String>) async {
        let targets = backups.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        isLoadingBackups = true
        errorMessage = nil
        defer { isLoadingBackups = false }

        let store = self.store
        let result = await Task.detached(priority: .userInitiated) {
            var moved = 0
            var failures: [String] = []
            for backup in targets {
                do {
                    try store.moveBackupToTrash(backup)
                    moved += 1
                } catch {
                    failures.append("\(backup.originalName): \(Self.readable(error))")
                }
            }
            return (moved: moved, failures: failures)
        }.value

        selectedBackupIDs.subtract(ids)
        await refreshBackups()
        if result.failures.isEmpty {
            status = "Moved \(result.moved) backups to trash"
        } else {
            errorMessage = result.failures.joined(separator: "\n")
            status = "Moved \(result.moved) backups, \(result.failures.count) failed"
        }
    }

    func restoreSelectedBackup() async {
        guard let backup = selectedBackups.first else { return }
        isLoadingBackups = true
        errorMessage = nil
        defer { isLoadingBackups = false }

        do {
            let store = self.store
            try await Task.detached(priority: .userInitiated) {
                try store.restoreBackup(backup)
            }.value
            status = "Restored \(backup.originalName)"
            await refresh()
        } catch {
            errorMessage = Self.readable(error)
            status = "Restore failed"
        }
    }

    func restoreSelectedTrashThread() async {
        guard let thread = selectedTrashThreads.first else { return }
        isLoadingBackups = true
        errorMessage = nil
        defer { isLoadingBackups = false }

        do {
            let store = self.store
            try await Task.detached(priority: .userInitiated) {
                try store.restoreTrashedThread(thread)
            }.value
            status = "Restored \(thread.title)"
            selectedTrashThreadIDs.remove(thread.id)
            await refresh()
            await refreshBackups()
            selectedProjectID = ProjectSummary.projectID(for: thread.cwd)
            setSelection([thread.threadID], preferredID: thread.threadID, shouldLoadPreview: true)
        } catch {
            errorMessage = Self.readable(error)
            status = "Restore failed"
        }
    }

    func deleteSelectedTrashThreadsPermanently() async {
        let targets = selectedTrashThreads
        guard !targets.isEmpty else { return }
        isLoadingBackups = true
        errorMessage = nil
        defer { isLoadingBackups = false }

        let store = self.store
        let result = await Task.detached(priority: .userInitiated) {
            var deleted = 0
            var failures: [String] = []
            for thread in targets {
                do {
                    try store.deleteTrashedThreadPermanently(thread)
                    deleted += 1
                } catch {
                    failures.append("\(thread.title): \(Self.readable(error))")
                }
            }
            return (deleted: deleted, failures: failures)
        }.value

        selectedTrashThreadIDs.subtract(Set(targets.map(\.id)))
        await refreshBackups()
        if result.failures.isEmpty {
            status = "Deleted \(result.deleted) trashed chats"
        } else {
            errorMessage = result.failures.joined(separator: "\n")
            status = "Deleted \(result.deleted) chats, \(result.failures.count) failed"
        }
    }

    func revealSelectedTrashThreadsInFinder() {
        guard !isDemoMode else {
            status = "Demo mode has no local trash files"
            return
        }
        let urls = selectedTrashThreads.compactMap { thread -> URL? in
            if let trashPath = thread.trashPath {
                return URL(fileURLWithPath: trashPath)
            }
            return URL(fileURLWithPath: thread.manifestPath)
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectedTrashThreadPaths() {
        let paths = selectedTrashThreads.map { thread in
            thread.trashPath ?? thread.manifestPath
        }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        status = paths.count == 1 ? "Trash path copied" : "\(paths.count) trash paths copied"
    }

    func revealSelectedTrashBackupsInFinder() {
        guard !isDemoMode else {
            status = "Demo mode has no local backup trash files"
            return
        }
        let urls = selectedTrashBackups.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectedTrashBackupPaths() {
        let paths = selectedTrashBackups.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        status = paths.count == 1 ? "Trash backup path copied" : "\(paths.count) trash backup paths copied"
    }

    func emptyBackupTrash() async {
        guard trashItemCount > 0 else { return }
        isLoadingBackups = true
        errorMessage = nil
        defer { isLoadingBackups = false }

        do {
            let store = self.store
            let removed = try await Task.detached(priority: .userInitiated) {
                let backups = try store.emptyBackupTrash()
                let threads = try store.emptyThreadTrash()
                return backups + threads
            }.value
            backupTrash.removeAll()
            threadTrash.removeAll()
            selectedTrashBackupIDs.removeAll()
            selectedTrashThreadIDs.removeAll()
            status = "Deleted \(removed) trashed items"
            await refreshBackups()
        } catch {
            errorMessage = Self.readable(error)
            status = "Empty trash failed"
        }
    }

    func revealSelectedBackupsInFinder() {
        guard !isDemoMode else {
            status = "Demo mode has no local backup files"
            return
        }
        let urls = selectedBackups.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectedBackupPaths() {
        let paths = selectedBackups.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        status = paths.count == 1 ? "Backup path copied" : "\(paths.count) backup paths copied"
    }

    func trimSelectedThread(from message: PreviewMessage) async {
        guard let thread = selectedThread, let lineNumber = message.lineNumber else { return }
        guard message.canTrimFromHere else {
            status = "Cannot trim the first visible user message"
            return
        }

        isLoading = true
        status = "Trimming chat..."
        errorMessage = nil
        operationReport = nil
        defer { isLoading = false }

        do {
            let store = self.store
            let report = try await Task.detached(priority: .userInitiated) {
                try store.trim(thread: thread, fromLine: lineNumber)
            }.value
            operationReport = OperationReport(
                title: "Trim complete",
                threadIDs: [report.threadID],
                timestamp: WakeDates.displayBackupStamp(report.timestamp),
                summary: "Removed \(report.removedLineCount) lines from line \(report.deletedFromLine)",
                backups: report.backups,
                changedFiles: report.changedFiles,
                failures: []
            )
            status = "Trim complete"
            invalidatePreviewCache(for: [thread.id])
            await refresh()
            setSelection([thread.id], preferredID: thread.id, shouldLoadPreview: true)
        } catch {
            errorMessage = Self.readable(error)
            status = "Trim failed"
        }
    }

    func branchSelectedThread(from message: PreviewMessage) async {
        guard let thread = selectedThread, let lineNumber = message.branchLineNumber else { return }

        isLoading = true
        status = "Creating chat branch..."
        errorMessage = nil
        operationReport = nil
        defer { isLoading = false }

        do {
            let store = self.store
            let report = try await Task.detached(priority: .userInitiated) {
                try store.branch(thread: thread, fromLine: lineNumber)
            }.value
            operationReport = OperationReport(
                title: "Branch created",
                threadIDs: [report.newThreadID],
                timestamp: WakeDates.displayBackupStamp(report.timestamp),
                summary: "Created \(report.title) with \(report.keptLineCount) kept lines",
                backups: report.backups,
                changedFiles: report.changedFiles,
                failures: []
            )
            status = "Branch created"
            await refresh()
            selectedProjectID = thread.projectID
            setSelection([report.newThreadID], preferredID: report.newThreadID, shouldLoadPreview: true)
        } catch {
            errorMessage = Self.readable(error)
            status = "Branch failed"
        }
    }

    func runDeepSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            status = "Type at least 3 characters for deep search"
            return
        }

        deepSearchTask?.cancel()
        isDeepSearching = true
        status = "Deep searching..."

        let selectedProject = selectedProjectID
        let source = threads.filter { thread in
            selectedProject == ProjectSummary.allID || thread.projectID == selectedProject
        }
        let metadataMatches = source.filter { $0.matchesMetadata(query) }
        let store = self.store

        deepSearchTask = Task { [weak self] in
            let rawMatches = await Task.detached(priority: .userInitiated) {
                source.filter { thread in
                    if metadataMatches.contains(where: { $0.id == thread.id }) { return false }
                    return (try? store.threadContainsRawText(thread, query: query)) == true
                }
            }.value

            guard !Task.isCancelled, let self else { return }
            self.filteredThreads = (metadataMatches + rawMatches).sorted { $0.updatedAt > $1.updatedAt }
            self.selectFirstFilteredThreadIfNeeded()
            self.isDeepSearching = false
            self.status = "Deep search found \(self.filteredThreads.count) chats"
            self.deepSearchTask = nil
        }
    }

    func cancelDeepSearch() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        isDeepSearching = false
        status = "Deep search cancelled"
        applyFilters()
    }

    func clearSearch() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        isDeepSearching = false
        searchText = ""
        status = "Search cleared"
    }

    @discardableResult
    func selectAdjacentThread(offset: Int, deferPreview: Bool = false) -> Bool {
        guard !filteredThreads.isEmpty else { return false }

        let currentIndex = selectedThreadID
            .flatMap { selectedID in filteredThreads.firstIndex { $0.id == selectedID } }
            ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), filteredThreads.count - 1)
        guard nextIndex != currentIndex else { return false }

        let nextThread = filteredThreads[nextIndex]
        setSelection([nextThread.id], preferredID: nextThread.id, shouldLoadPreview: !deferPreview)
        if deferPreview {
            startKeyboardPreviewLoad(threadID: nextThread.id)
        }
        return true
    }

    @discardableResult
    func selectThreadBoundary(_ boundary: BoundarySelection, deferPreview: Bool = false) -> Bool {
        guard let target = boundary.target(in: filteredThreads) else { return false }
        guard target.id != selectedThreadID else { return false }

        setSelection([target.id], preferredID: target.id, shouldLoadPreview: !deferPreview)
        if deferPreview {
            startKeyboardPreviewLoad(threadID: target.id)
        }
        return true
    }

    @discardableResult
    func selectAdjacentProject(offset: Int) -> Bool {
        guard !projects.isEmpty else { return false }

        let currentIndex = projects.firstIndex { $0.id == selectedProjectID } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), projects.count - 1)
        guard nextIndex != currentIndex else { return false }

        selectedProjectID = projects[nextIndex].id
        return true
    }

    @discardableResult
    func selectProjectBoundary(_ boundary: BoundarySelection) -> Bool {
        guard let target = boundary.target(in: projects) else { return false }
        guard target.id != selectedProjectID else { return false }

        selectedProjectID = target.id
        return true
    }

    private func applyFilters() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        isDeepSearching = false
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedProject = selectedProjectID
        let source = threads.filter { thread in
            selectedProject == ProjectSummary.allID || thread.projectID == selectedProject
        }

        guard !query.isEmpty else {
            filteredThreads = source
            selectFirstFilteredThreadIfNeeded()
            return
        }

        filteredThreads = source.filter { thread in
            thread.matchesMetadata(query)
        }
        selectFirstFilteredThreadIfNeeded()
    }

    private func selectFirstFilteredThreadIfNeeded() {
        guard !filteredThreads.isEmpty else {
            selectedThreadIDs = []
            selectedThreadID = nil
            cancelPreviewLoad(clearPreview: true)
            return
        }

        let visibleIDs = Set(filteredThreads.map(\.id))
        var retainedSelection = selectedThreadIDs.intersection(visibleIDs)
        if retainedSelection.isEmpty, let first = filteredThreads.first {
            retainedSelection = [first.id]
        }
        setSelection(retainedSelection, shouldLoadPreview: true)
    }

    private func setSelection(_ ids: Set<String>, preferredID: String? = nil, shouldLoadPreview: Bool) {
        let visibleIDs = Set(filteredThreads.map(\.id))
        let validIDs = ids.intersection(visibleIDs)
        selectedThreadIDs = validIDs

        let nextID: String?
        if let preferredID, validIDs.contains(preferredID) {
            nextID = preferredID
        } else if let selectedThreadID, validIDs.contains(selectedThreadID) {
            nextID = selectedThreadID
        } else {
            nextID = filteredThreads.first(where: { validIDs.contains($0.id) })?.id
        }

        guard nextID != selectedThreadID else {
            if shouldLoadPreview,
               let nextID,
               preview?.threadID != nextID,
               !isPreviewLoading {
                startPreviewLoad(threadID: nextID)
            }
            return
        }
        selectedThreadID = nextID
        cancelPreviewLoad(clearPreview: true)
        if shouldLoadPreview, let nextID {
            startPreviewLoad(threadID: nextID)
        }
    }

    private func cancelPreviewLoad(clearPreview: Bool) {
        previewDebounceTask?.cancel()
        previewDebounceTask = nil
        previewTask?.cancel()
        previewTask = nil
        isPreviewLoading = false
        if clearPreview {
            preview = nil
        }
    }

    private func cachedPreview(for threadID: String) -> ThreadPreview? {
        guard let cached = previewCache[threadID] else { return nil }
        previewCacheOrder.removeAll { $0 == threadID }
        previewCacheOrder.append(threadID)
        return cached
    }

    private func cachePreview(_ threadPreview: ThreadPreview) {
        previewCache[threadPreview.threadID] = threadPreview
        previewCacheOrder.removeAll { $0 == threadPreview.threadID }
        previewCacheOrder.append(threadPreview.threadID)
        while previewCacheOrder.count > previewCacheLimit {
            let removedID = previewCacheOrder.removeFirst()
            previewCache.removeValue(forKey: removedID)
        }
    }

    private func invalidatePreviewCache(for threadIDs: Set<String>) {
        guard !threadIDs.isEmpty else { return }
        for threadID in threadIDs {
            previewCache.removeValue(forKey: threadID)
        }
        previewCacheOrder.removeAll { threadIDs.contains($0) }
    }

    private func orderedThreads(for ids: Set<String>) -> [CodexThread] {
        guard !ids.isEmpty else { return [] }

        var seen: Set<String> = []
        var ordered: [CodexThread] = []
        for thread in filteredThreads + threads {
            guard ids.contains(thread.id), !seen.contains(thread.id) else { continue }
            ordered.append(thread)
            seen.insert(thread.id)
        }
        return ordered
    }

    private nonisolated static func readable(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private nonisolated static func detectDemoMode() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        return args.contains("--demo") || env["CODEX_WAKE_DEMO"] == "1"
    }

    private func showCommandLineToolInstallAlert(_ result: CommandLineToolInstallResult) {
        let alert = NSAlert()
        alert.messageText = "Command line tool installed"
        alert.informativeText = """
        Installed codex-keeper to:
        \(result.installedPath)

        Run:
        codex-keeper --help
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCommandLineToolInstallError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not install command line tool"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCommandLineToolUninstallAlert(_ result: CommandLineToolUninstallResult) {
        let alert = NSAlert()
        if result.didRemove {
            alert.messageText = "Command line tool uninstalled"
            alert.informativeText = """
            Removed:
            \(result.installPath)

            The Codex Keeper app is unchanged.
            """
        } else {
            alert.messageText = "Command line tool was not installed"
            alert.informativeText = """
            Nothing was removed at:
            \(result.installPath)

            The Codex Keeper app is unchanged.
            """
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCommandLineToolUninstallError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not uninstall command line tool"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum BoundarySelection {
    case first
    case last

    func target<T>(in values: [T]) -> T? {
        switch self {
        case .first: values.first
        case .last: values.last
        }
    }
}

private struct BatchOperationResult {
    let targetIDs: Set<String>
    let successIDs: Set<String>
    let backups: [String]
    let changedFiles: [String]
    let failures: [String]
}
