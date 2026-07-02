import ArgumentParser
import CodexKeeperCore
import Foundation

@main
struct CodexKeeperCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-keeper",
        abstract: "Local Codex chat maintenance CLI.",
        subcommands: [
            Doctor.self,
            Chats.self,
            Projects.self,
            Backups.self
        ]
    )
}

struct StoreOptions: ParsableArguments {
    @Option(name: .customLong("codex-home"), help: "Path to the Codex data directory. Defaults to ~/.codex.")
    var codexHome: String?

    @Flag(name: .long, help: "Use synthetic demo data instead of reading ~/.codex.")
    var demo = false

    func makeStore() -> any ThreadStore {
        if demo {
            return DemoCodexStore()
        }
        return makeCodexStore()
    }

    func makeCodexStore() -> CodexStore {
        CodexStore(codexHome: codexHomeURL)
    }

    var codexHomeURL: URL? {
        guard let codexHome else { return nil }
        return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check local Codex Keeper inputs.")

    @OptionGroup var storeOptions: StoreOptions
    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        try runCLI {
            let payload: DoctorOutput
            if storeOptions.demo {
                let store = storeOptions.makeStore()
                let threads = try store.loadThreads()
                let projects = ProjectSummary.make(from: threads)
                payload = DoctorOutput(
                    codexHome: "demo",
                    sessionIndexPath: "demo",
                    sessionIndexExists: false,
                    sessionsPath: "demo",
                    sessionsExists: false,
                    stateRoots: [],
                    activeStateRoot: nil,
                    threadCount: threads.count,
                    projectCount: projects.filter { !$0.isSynthetic }.count,
                    backupCount: try store.loadBackups().count,
                    trashCount: try store.loadBackupTrash().count + store.loadThreadTrash().count
                )
            } else {
                payload = DoctorOutput(try storeOptions.makeCodexStore().diagnostics())
            }
            try printDoctor(payload, json: json)
        }
    }
}

struct Chats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find, inspect, and wake Codex chats.",
        subcommands: [
            List.self,
            Search.self,
            Show.self,
            Wake.self
        ]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recent chats.")

        @OptionGroup var storeOptions: StoreOptions
        @Option(name: .long, help: "Filter by project name, project path, or project id.")
        var project: String?
        @Option(name: .long, help: "Maximum number of chats to print.")
        var limit = 20
        @Flag(name: .long, help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            try runCLI {
                let threads = try filteredThreads(
                    store: storeOptions.makeStore(),
                    project: project,
                    query: nil,
                    deep: false,
                    limit: limit
                )
                try printThreads(threads, json: json)
            }
        }
    }

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search chats by metadata, optionally scanning JSONL content.")

        @OptionGroup var storeOptions: StoreOptions
        @Argument(help: "Text to search for.")
        var query: String
        @Option(name: .long, help: "Filter by project name, project path, or project id.")
        var project: String?
        @Option(name: .long, help: "Maximum number of chats to print.")
        var limit = 20
        @Flag(name: .long, help: "Search inside chat JSONL files after metadata matching.")
        var deep = false
        @Flag(name: .long, help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            try runCLI {
                let threads = try filteredThreads(
                    store: storeOptions.makeStore(),
                    project: project,
                    query: query,
                    deep: deep,
                    limit: limit
                )
                try printThreads(threads, json: json)
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one chat by id or unique id prefix.")

        @OptionGroup var storeOptions: StoreOptions
        @Argument(help: "Thread id or unique id prefix.")
        var id: String
        @Option(name: .long, help: "Maximum preview messages to include.")
        var messages = 8
        @Flag(name: .long, help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            try runCLI {
                let store = storeOptions.makeStore()
                let thread = try resolveThread(id, in: try store.loadThreads())
                let preview = try? store.loadPreview(for: thread)
                let payload = ThreadDetailOutput(
                    thread: thread,
                    messages: Array((preview?.messages ?? []).prefix(max(0, messages))),
                    rawError: preview?.rawError
                )
                if json {
                    try printJSON(payload)
                } else {
                    printThreadDetail(payload)
                }
            }
        }
    }

    struct Wake: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a chat timestamp so it becomes recent again.")

        @OptionGroup var storeOptions: StoreOptions
        @Argument(help: "Thread id or unique id prefix.")
        var id: String
        @Flag(name: .long, help: "Show what would change without writing files.")
        var dryRun = false
        @Flag(name: .long, help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            try runCLI {
                let store = storeOptions.makeStore()
                let thread = try resolveThread(id, in: try store.loadThreads())
                let plan = try makeWakePlan(for: thread, storeOptions: storeOptions)

                if dryRun {
                    try printWakeResult(dryRun: true, plan: plan, report: nil, thread: thread, json: json)
                    return
                }

                let report = try store.wake(thread: thread)
                try printWakeResult(dryRun: false, plan: plan, report: report, thread: thread, json: json)
            }
        }
    }
}

struct Projects: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect Codex chat projects.",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List projects known from local chats.")

        @OptionGroup var storeOptions: StoreOptions
        @Flag(name: .long, help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            try runCLI {
                let projects = ProjectSummary.make(from: try storeOptions.makeStore().loadThreads())
                let rows = projects.map(ProjectOutput.init)
                if json {
                    try printJSON(rows)
                } else {
                    for row in rows {
                        print("\(row.name)\t\(row.totalCount) chats\t\(row.path)")
                    }
                }
            }
        }
    }
}

struct Backups: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect Codex Keeper backups.",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List chat backups.")

        @OptionGroup var storeOptions: StoreOptions
        @Option(name: .long, help: "Maximum number of backups to print.")
        var limit = 20
        @Flag(name: .long, help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            try runCLI {
                let backups = Array(try storeOptions.makeStore().loadBackups().prefix(max(0, limit)))
                let rows = backups.map(BackupOutput.init)
                if json {
                    try printJSON(rows)
                } else {
                    for row in rows {
                        print("\(row.createdAt ?? "-")\t\(row.kind)\t\(row.originalName)\t\(row.path)")
                    }
                }
            }
        }
    }
}

private func filteredThreads(
    store: any ThreadStore,
    project: String?,
    query: String?,
    deep: Bool,
    limit: Int
) throws -> [CodexThread] {
    let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    let threads = try store.loadThreads()
    var matches = threads.filter { thread in
        guard let project, !project.isEmpty else { return true }
        return matchesProject(thread, project: project)
    }

    if let normalizedQuery, !normalizedQuery.isEmpty {
        matches = matches.filter { thread in
            if thread.matchesMetadata(normalizedQuery) {
                return true
            }
            guard deep else { return false }
            return (try? store.threadContainsRawText(thread, query: normalizedQuery)) == true
        }
    }

    return Array(matches.prefix(max(0, limit)))
}

private func matchesProject(_ thread: CodexThread, project: String) -> Bool {
    let q = project.lowercased()
    return thread.projectID.lowercased().contains(q)
        || thread.projectName.lowercased().contains(q)
        || thread.cwd.lowercased().contains(q)
}

private func resolveThread(_ id: String, in threads: [CodexThread]) throws -> CodexThread {
    let exact = threads.filter { $0.id == id }
    if exact.count == 1 {
        return exact[0]
    }

    let prefixMatches = threads.filter { $0.id.hasPrefix(id) }
    if prefixMatches.count == 1 {
        return prefixMatches[0]
    }
    if prefixMatches.isEmpty {
        try fail("No chat matches id or prefix: \(id)", code: 1)
    }
    try fail("Ambiguous chat id prefix: \(id)", code: 2)
}

private func makeWakePlan(for thread: CodexThread, storeOptions: StoreOptions) throws -> WakePlan {
    if storeOptions.demo {
        return WakePlan(
            threadID: thread.id,
            title: thread.shortTitle,
            project: thread.projectName,
            projectPath: thread.cwd,
            updatedAt: thread.updatedAt,
            rolloutPath: thread.rolloutPath,
            sessionIndexPath: "demo",
            stateDatabasePaths: []
        )
    }
    return try storeOptions.makeCodexStore().wakePlan(for: thread)
}

private func printDoctor(_ payload: DoctorOutput, json: Bool) throws {
    if json {
        try printJSON(payload)
        return
    }

    print("Codex Keeper doctor")
    print("codex home: \(payload.codexHome)")
    print("session index: \(payload.sessionIndexExists ? "ok" : "missing") \(payload.sessionIndexPath)")
    print("sessions: \(payload.sessionsExists ? "ok" : "missing") \(payload.sessionsPath)")
    if payload.stateRoots.isEmpty {
        print("state roots: none")
    } else {
        print("state roots:")
        for root in payload.stateRoots {
            let primary = root.isPrimary ? " primary" : ""
            print("- \(root.kind)\(primary): \(root.exists ? "ok" : "missing") \(root.path)")
        }
    }
    if let active = payload.activeStateRoot {
        print("active root: \(active.kind) \(active.path)")
    }
    print("chats: \(payload.threadCount)")
    print("projects: \(payload.projectCount)")
    print("backups: \(payload.backupCount)")
    print("trash: \(payload.trashCount)")
}

private func printThreads(_ threads: [CodexThread], json: Bool) throws {
    let rows = threads.map(ThreadOutput.init)
    if json {
        try printJSON(rows)
        return
    }

    for row in rows {
        print("\(row.updatedAt)\t\(row.status)\t\(row.title)\t\(row.id)")
    }
}

private func printThreadDetail(_ payload: ThreadDetailOutput) {
    let thread = payload.thread
    print("title: \(thread.title)")
    print("id: \(thread.id)")
    print("status: \(thread.status)")
    print("project: \(thread.project)")
    print("cwd: \(thread.cwd)")
    print("path: \(thread.rolloutPath)")
    print("updated: \(thread.updatedAt)")
    if let rawError = payload.rawError {
        print("preview warning: \(rawError)")
    }
    for message in payload.messages {
        print("")
        print("[\(message.role)] \(message.timestamp ?? "-")")
        print(message.text)
    }
}

private func printWakeResult(
    dryRun: Bool,
    plan: WakePlan,
    report: WakeReport?,
    thread: CodexThread,
    json: Bool
) throws {
    if json {
        try printJSON(WakeOutput(dryRun: dryRun, plan: WakePlanOutput(plan), report: report.map(WakeReportOutput.init)))
        return
    }

    print(dryRun ? "Wake dry run" : "Woke chat")
    print("title: \(thread.shortTitle)")
    print("project: \(thread.projectName)")
    print("id: \(thread.id)")
    print("current updated: \(DateOutput.string(plan.updatedAt))")
    print("would change:")
    for path in plan.stateDatabasePaths {
        print("- \(path)")
    }
    print("- \(plan.sessionIndexPath)")
    print("- \(plan.rolloutPath)")

    guard let report else { return }
    print("timestamp: \(report.timestamp)")
    print("changed files:")
    for path in report.changedFiles {
        print("- \(path)")
    }
    print("backups:")
    for path in report.backups {
        print("- \(path)")
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else { return }
    print(json)
}

private func runCLI(_ work: () throws -> Void) throws {
    do {
        try work()
    } catch let exitCode as ExitCode {
        throw exitCode
    } catch {
        printError(readable(error))
        throw exitCode(for: error)
    }
}

private func fail(_ message: String, code: Int32) throws -> Never {
    printError(message)
    throw ExitCode(code)
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func readable(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription {
        return description
    }
    return error.localizedDescription
}

private func exitCode(for error: Error) -> ExitCode {
    switch error {
    case WakeError.missingCodexHome,
         WakeError.missingStateDatabase,
         WakeError.missingThreadFile:
        return ExitCode(1)
    case WakeError.invalidJSON:
        return ExitCode(3)
    default:
        return ExitCode(1)
    }
}

private enum DateOutput {
    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func optional(_ date: Date?) -> String? {
        date.map(string)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct ThreadOutput: Encodable {
    let id: String
    let title: String
    let project: String
    let cwd: String
    let rolloutPath: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let fileExists: Bool
    let isInSessionIndex: Bool
    let archived: Bool

    init(_ thread: CodexThread) {
        id = thread.id
        title = thread.shortTitle
        project = thread.projectName
        cwd = thread.cwd
        rolloutPath = thread.rolloutPath
        status = thread.statusLabel
        createdAt = DateOutput.string(thread.createdAt)
        updatedAt = DateOutput.string(thread.updatedAt)
        fileExists = thread.fileExists
        isInSessionIndex = thread.isInSessionIndex
        archived = thread.archived
    }
}

private struct ThreadDetailOutput: Encodable {
    let thread: ThreadOutput
    let messages: [MessageOutput]
    let rawError: String?

    init(thread: CodexThread, messages: [PreviewMessage], rawError: String?) {
        self.thread = ThreadOutput(thread)
        self.messages = messages.map(MessageOutput.init)
        self.rawError = rawError
    }
}

private struct MessageOutput: Encodable {
    let role: String
    let text: String
    let timestamp: String?
    let lineNumber: Int?
    let branchLineNumber: Int?
    let isTurnStart: Bool

    init(_ message: PreviewMessage) {
        role = message.role
        text = message.text
        timestamp = message.timestamp
        lineNumber = message.lineNumber
        branchLineNumber = message.branchLineNumber
        isTurnStart = message.isTurnStart
    }
}

private struct ProjectOutput: Encodable {
    let id: String
    let name: String
    let path: String
    let totalCount: Int
    let repairCount: Int
    let availableCount: Int
    let latestUpdatedAt: String?

    init(_ project: ProjectSummary) {
        id = project.id
        name = project.name
        path = project.path
        totalCount = project.totalCount
        repairCount = project.repairCount
        availableCount = project.availableCount
        latestUpdatedAt = DateOutput.optional(project.latestUpdatedAt)
    }
}

private struct BackupOutput: Encodable {
    let path: String
    let originalPath: String
    let originalName: String
    let kind: String
    let createdAt: String?
    let modifiedAt: String?
    let size: Int64
    let originalExists: Bool
    let chatTitle: String?
    let reason: String

    init(_ backup: BackupFile) {
        path = backup.backupPath
        originalPath = backup.originalPath
        originalName = backup.originalName
        kind = backup.kind.rawValue
        createdAt = DateOutput.optional(backup.createdAt)
        modifiedAt = DateOutput.optional(backup.modifiedAt)
        size = backup.size
        originalExists = backup.originalExists
        chatTitle = backup.chatTitle
        reason = backup.reason
    }
}

private struct WakePlanOutput: Encodable {
    let threadID: String
    let title: String
    let project: String
    let projectPath: String
    let currentUpdatedAt: String
    let rolloutPath: String
    let sessionIndexPath: String
    let stateDatabasePaths: [String]

    init(_ plan: WakePlan) {
        threadID = plan.threadID
        title = plan.title
        project = plan.project
        projectPath = plan.projectPath
        currentUpdatedAt = DateOutput.string(plan.updatedAt)
        rolloutPath = plan.rolloutPath
        sessionIndexPath = plan.sessionIndexPath
        stateDatabasePaths = plan.stateDatabasePaths
    }
}

private struct WakeReportOutput: Encodable {
    let threadID: String
    let timestamp: String
    let backups: [String]
    let changedFiles: [String]

    init(_ report: WakeReport) {
        threadID = report.threadID
        timestamp = report.timestamp
        backups = report.backups
        changedFiles = report.changedFiles
    }
}

private struct WakeOutput: Encodable {
    let dryRun: Bool
    let plan: WakePlanOutput
    let report: WakeReportOutput?
}

private struct DoctorOutput: Encodable {
    let codexHome: String
    let sessionIndexPath: String
    let sessionIndexExists: Bool
    let sessionsPath: String
    let sessionsExists: Bool
    let stateRoots: [StateRootOutput]
    let activeStateRoot: StateRootOutput?
    let threadCount: Int
    let projectCount: Int
    let backupCount: Int
    let trashCount: Int

    init(
        codexHome: String,
        sessionIndexPath: String,
        sessionIndexExists: Bool,
        sessionsPath: String,
        sessionsExists: Bool,
        stateRoots: [StateRootOutput],
        activeStateRoot: StateRootOutput?,
        threadCount: Int,
        projectCount: Int,
        backupCount: Int,
        trashCount: Int
    ) {
        self.codexHome = codexHome
        self.sessionIndexPath = sessionIndexPath
        self.sessionIndexExists = sessionIndexExists
        self.sessionsPath = sessionsPath
        self.sessionsExists = sessionsExists
        self.stateRoots = stateRoots
        self.activeStateRoot = activeStateRoot
        self.threadCount = threadCount
        self.projectCount = projectCount
        self.backupCount = backupCount
        self.trashCount = trashCount
    }

    init(_ diagnostics: CodexDiagnostics) {
        codexHome = diagnostics.codexHome
        sessionIndexPath = diagnostics.sessionIndexPath
        sessionIndexExists = diagnostics.sessionIndexExists
        sessionsPath = diagnostics.sessionsPath
        sessionsExists = diagnostics.sessionsExists
        stateRoots = diagnostics.stateRoots.map(StateRootOutput.init)
        activeStateRoot = diagnostics.activeStateRoot.map(StateRootOutput.init)
        threadCount = diagnostics.threadCount
        projectCount = diagnostics.projectCount
        backupCount = diagnostics.backupCount
        trashCount = diagnostics.trashCount
    }
}

private struct StateRootOutput: Encodable {
    let kind: String
    let path: String
    let isPrimary: Bool
    let exists: Bool

    init(_ root: StateRootStatus) {
        kind = root.kind.rawValue
        path = root.path
        isPrimary = root.isPrimary
        exists = root.exists
    }

    init(_ root: ActiveStateRoot) {
        kind = root.kind.rawValue
        path = root.path
        isPrimary = true
        exists = true
    }
}
