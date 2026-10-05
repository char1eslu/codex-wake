import Foundation
import CodexKeeperCore

@main
private struct CompatibilityTestRunner {
    static func main() throws {
        let suite = CodexStoreCompatibilityTests()
        try suite.testSubagentsAreFoldedIntoParentAndNeverListedForRepair()
        try suite.testModernThreadMetadataAndSubagentsCanBeProjected()
        try suite.testMoveUpdatesSQLiteRolloutAndNativeProjectMetadata()
        try suite.testTrashAndRestorePreserveCurrentMetadataAndRelations()
        try suite.testCompressedRolloutsStayFullyUsable()
        try suite.testClientProjectAssignmentsDriveGrouping()
        print("Codex Keeper compatibility tests passed")
    }
}

struct CodexStoreCompatibilityTests {
    func testSubagentsAreFoldedIntoParentAndNeverListedForRepair() throws {
        let fixture = try CodexFixture()
        defer { try? fixture.remove() }
        let threads = try fixture.store.loadThreads()

        try expect(threads.map(\.id) == [fixture.rootID], "Only the parent thread should be listed")
        try expect(threads.first?.childThreadCount == 1, "Parent should report one subagent")
        try expect(threads.first?.isSubagent == false, "Parent must not be classified as a subagent")
        try expect(threads.first?.needsRepair == false, "Indexed parent must not need repair")
    }

    func testModernThreadMetadataAndSubagentsCanBeProjected() throws {
        let fixture = try CodexFixture()
        defer { try? fixture.remove() }

        let visible = try fixture.store.loadThreads()
        let parent = try require(visible.first, "Fixture parent thread is missing")
        try expect(parent.modelProvider == "openai", "Model provider was not projected")
        try expect(parent.model == "gpt-test", "Model was not projected")
        try expect(parent.reasoningEffort == "high", "Reasoning effort was not projected")
        try expect(parent.approvalMode == "never", "Approval mode was not projected")
        try expect(parent.sandboxPolicy == "{}", "Sandbox policy was not projected")
        try expect(parent.tokensUsed == 10, "Token usage was not projected")
        try expect(parent.activityAt == parent.recencyAt, "Recent activity did not drive thread ordering")
        try expect(parent.gitBranch == nil, "Unexpected Git branch was projected")
        try expect(parent.isPinned, "Pinned state was not projected")
        try expect(parent.threadSectionID == "section-1", "Thread section was not projected")
        try expect(parent.childThreadIDs == [fixture.childID], "Child thread relationship was not projected")

        let allThreads = try fixture.store.loadThreads(includeSubagents: true)
        try expect(allThreads.map(\.id).count == 2, "Subagent-inclusive projection should include both threads")
        let child = try require(allThreads.first(where: { $0.id == fixture.childID }), "Child thread is missing")
        try expect(child.parentThreadID == fixture.rootID, "Child parent relationship was not projected")
        try expect(child.agentRole == "research-worker", "Agent role was not projected")
        try expect(child.agentPath == "/root/scout", "Agent path was not projected")
    }

    func testMoveUpdatesSQLiteRolloutAndNativeProjectMetadata() throws {
        let fixture = try CodexFixture()
        defer { try? fixture.remove() }
        let thread = try require(fixture.store.loadThreads().first, "Fixture parent thread is missing")
        let destination = ProjectSummary(
            id: fixture.destinationPath,
            name: "Destination",
            path: fixture.destinationPath,
            totalCount: 0,
            repairCount: 0,
            availableCount: 0,
            latestUpdatedAt: nil
        )

        _ = try fixture.store.move(thread: thread, to: destination)

        try expect(try fixture.query("select cwd from threads where id = '\(fixture.rootID)';") == fixture.destinationPath, "SQLite cwd was not moved")
        let rollout = try fixture.readJSONLMeta(at: fixture.rootRollout)
        try expect((rollout["payload"] as? [String: Any])?["cwd"] as? String == fixture.destinationPath, "Rollout cwd was not moved")

        let state = try fixture.readGlobalState()
        let assignment = (state["thread-project-assignments"] as? [String: Any])?[fixture.rootID] as? [String: Any]
        try expect(assignment?["projectId"] as? String == fixture.destinationProjectID, "Native project assignment was not moved")
        let orders = state["sidebar-project-thread-orders"] as? [String: Any]
        let sourceIDs = (orders?[fixture.sourceProjectID] as? [String: Any])?["threadIds"] as? [String]
        let destinationIDs = (orders?[fixture.destinationProjectID] as? [String: Any])?["threadIds"] as? [String]
        try expect(sourceIDs?.contains(fixture.rootID) == false, "Source sidebar still contains moved thread")
        try expect(destinationIDs?.first == fixture.rootID, "Destination sidebar does not contain moved thread")
    }

    func testTrashAndRestorePreserveCurrentMetadataAndRelations() throws {
        let fixture = try CodexFixture()
        defer { try? fixture.remove() }
        let thread = try require(fixture.store.loadThreads().first, "Fixture parent thread is missing")
        _ = try fixture.store.moveThreadToTrash(thread)

        try expect(try fixture.query("select count(*) from threads where id = '\(fixture.rootID)';") == "0", "Thread row remains after trash")
        try expect(try fixture.query("select count(*) from thread_dynamic_tools where thread_id = '\(fixture.rootID)';") == "0", "Dynamic tools remain after trash")
        try expect(try fixture.query("select count(*) from thread_spawn_edges where parent_thread_id = '\(fixture.rootID)';") == "0", "Spawn edges remain after trash")
        // `thread_attachments` is discovered from the live schema. Restore has to
        // reinstate it too, or trashing a chat silently drops its attachments.
        try expect(try fixture.query("select count(*) from thread_attachments where thread_id = '\(fixture.rootID)';") == "0", "Attachments remain after trash")
        try expect(try fixture.queryCatalog("select count(*) from local_thread_catalog where thread_id = '\(fixture.rootID)';") == "0", "Catalog row remains after trash")
        try expect(try fixture.queryCatalog("select catalog_revision from local_thread_catalog_metadata where id = 1;") == "5", "Catalog revision was not advanced after trash")
        try expect(try fixture.queryHistorySnapshots("select count(*) from app_server_history_snapshots where thread_id = '\(fixture.rootID)';") == "0", "History snapshot remains after trash")
        // `thread_history_1.sqlite` holds the transcript. A relative path computed
        // from an unresolved base used to point at a file that does not exist, so
        // Trash silently skipped it and left the transcript orphaned.
        try expect(try fixture.queryHistory("select count(*) from thread_items where thread_id = '\(fixture.rootID)';") == "0", "Transcript items remain after trash")
        try expect(try fixture.queryHistory("select count(*) from thread_turns where thread_id = '\(fixture.rootID)';") == "0", "Transcript turns remain after trash")
        try expect(try fixture.queryHistory("select count(*) from thread_history_projection_state where thread_id = '\(fixture.rootID)';") == "0", "Transcript projection state remains after trash")
        try expect(try fixture.queryHistory("select count(*) from thread_items where thread_id = '\(fixture.decoyID)';") == "1", "Trash removed another chat's transcript items")
        try expect(try fixture.queryHistory("select count(*) from thread_turns where thread_id = '\(fixture.decoyID)';") == "1", "Trash removed another chat's transcript turns")
        try expect(!FileManager.default.fileExists(atPath: fixture.rootRollout.path), "Rollout remains after trash")
        let removedState = try fixture.readGlobalState()
        try expect((removedState["thread-project-assignments"] as? [String: Any])?[fixture.rootID] == nil, "Global assignment remains after trash")

        let trashed = try require(fixture.store.loadThreadTrash().first, "Trashed thread manifest is missing")
        try fixture.store.restoreTrashedThread(trashed)

        try expect(FileManager.default.fileExists(atPath: fixture.rootRollout.path), "Rollout was not restored")
        try expect(try fixture.query("select name || '|' || is_pinned || '|' || history_mode from threads where id = '\(fixture.rootID)';") == "Pinned root|1|legacy", "Current thread metadata was not restored")
        try expect(try fixture.query("select count(*) from thread_dynamic_tools where thread_id = '\(fixture.rootID)';") == "1", "Dynamic tools were not restored")
        try expect(try fixture.query("select status from thread_spawn_edges where parent_thread_id = '\(fixture.rootID)';") == "open", "Spawn edge was not restored")
        try expect(try fixture.query("select payload from thread_attachments where thread_id = '\(fixture.rootID)';") == "{\"fixture\":true}", "Attachment was not restored")
        try expect(try fixture.queryCatalog("select display_title from local_thread_catalog where thread_id = '\(fixture.rootID)';") == "Catalog root", "Catalog row was not restored")
        try expect(try fixture.queryCatalog("select catalog_revision from local_thread_catalog_metadata where id = 1;") == "6", "Catalog revision was not advanced after restore")
        try expect(try fixture.queryHistorySnapshots("select payload_json from app_server_history_snapshots where thread_id = '\(fixture.rootID)';") == "{\"fixture\":true}", "History snapshot was not restored")
        try expect(try fixture.queryHistory("select count(*) from thread_items where thread_id = '\(fixture.rootID)';") == "2", "Transcript items were not restored")
        try expect(try fixture.queryHistory("select count(*) from thread_turns where thread_id = '\(fixture.rootID)';") == "1", "Transcript turns were not restored")
        try expect(try fixture.queryHistory("select next_rollout_byte_offset from thread_history_projection_state where thread_id = '\(fixture.rootID)';") == "4096", "Transcript projection state was not restored")
        try expect(try fixture.queryHistory("select count(*) from thread_items where thread_id = '\(fixture.decoyID)';") == "1", "Restore disturbed another chat's transcript items")
        let restoredState = try fixture.readGlobalState()
        let assignment = (restoredState["thread-project-assignments"] as? [String: Any])?[fixture.rootID] as? [String: Any]
        try expect(assignment?["projectId"] as? String == fixture.sourceProjectID, "Native project assignment was not restored")
        try expect(try fixture.store.loadThreads().first?.childThreadCount == 1, "Restored parent lost its child count")
    }

    /// Codex ages rollouts out by replacing `rollout-*.jsonl` with a
    /// zstd-compressed `.jsonl.zst` sibling while `rollout_path` in the state
    /// database keeps naming the uncompressed file. A compressed chat is still a
    /// real chat, so it has to stay previewable, searchable, trimmable,
    /// branchable, movable, and restorable — and a restore must put it back under
    /// the name it was stored with.
    func testCompressedRolloutsStayFullyUsable() throws {
        let fixture = try CodexFixture()
        defer { try? fixture.remove() }

        // Give the root chat a second line so Trim and Branch have a line to act
        // on, then compress it the way Codex does.
        try fixture.appendJSONLine(
            ["type": "response_item", "payload": ["type": "message", "role": "user"]],
            to: fixture.rootRollout
        )
        try fixture.compressRootRollout()
        try expect(
            !FileManager.default.fileExists(atPath: fixture.rootRollout.path),
            "Compressing the fixture left the plain rollout behind"
        )

        let thread = try fixture.rootThread()
        try expect(thread.fileExists, "A compressed rollout must still count as present")
        try expect(thread.statusLabel != "Missing file", "A compressed rollout must not be reported as a missing file")
        try expect(thread.isAvailable, "A compressed rollout must stay available")

        // Preview reads through the decompressor.
        _ = try fixture.store.loadPreview(for: thread)

        // Search streams the decompressed file and still matches content.
        let found = try fixture.store.threadContainsRawText(thread, query: fixture.rootID)
        try expect(found, "Content search missed a match inside a compressed rollout")
        let absent = try fixture.store.threadContainsRawText(thread, query: "definitely-not-present")
        try expect(!absent, "Content search reported a match that is not there")

        // Move rewrites the session metadata, so the rollout is expanded first.
        let destination = ProjectSummary(
            id: fixture.destinationPath,
            name: "Destination",
            path: fixture.destinationPath,
            totalCount: 0,
            repairCount: 0,
            availableCount: 0,
            latestUpdatedAt: nil
        )
        _ = try fixture.store.move(thread: thread, to: destination)
        try expect(FileManager.default.fileExists(atPath: fixture.rootRollout.path), "Move did not leave a plain rollout behind")
        try expect(
            !FileManager.default.fileExists(atPath: fixture.rootRollout.path + RolloutFile.compressedSuffix),
            "Move left the stale compressed rollout behind"
        )
        let moved = try fixture.readJSONLMeta(at: fixture.rootRollout)
        try expect(
            (moved["payload"] as? [String: Any])?["cwd"] as? String == fixture.destinationPath,
            "Move did not rewrite the compressed rollout"
        )

        // Branch only reads the source, so a compressed source must not be
        // expanded on disk.
        try fixture.compressRootRollout()
        let branch = try fixture.store.branch(thread: try fixture.rootThread(), fromLine: 2)
        try expect(FileManager.default.fileExists(atPath: branch.rolloutPath), "Branch did not write its new rollout")
        try expect(
            FileManager.default.fileExists(atPath: fixture.rootRollout.path + RolloutFile.compressedSuffix),
            "Branching expanded the compressed source"
        )
        try expect(
            !FileManager.default.fileExists(atPath: fixture.rootRollout.path),
            "Branching left a plain copy of the compressed source"
        )

        // Trim rewrites the compressed chat in place.
        let trim = try fixture.store.trim(thread: try fixture.rootThread(), fromLine: 2)
        try expect(trim.removedLineCount == 1, "Trim removed the wrong number of lines from a compressed rollout")
        try expect(FileManager.default.fileExists(atPath: fixture.rootRollout.path), "Trim did not leave a plain rollout behind")
        try expect(
            !FileManager.default.fileExists(atPath: fixture.rootRollout.path + RolloutFile.compressedSuffix),
            "Trim left the stale compressed rollout behind"
        )
        try expect(
            try fixture.readJSONLMeta(at: fixture.rootRollout)["type"] as? String == "session_meta",
            "Trim corrupted the compressed rollout"
        )

        // Trash and restore must return the chat under the `.zst` name, not as a
        // zstd stream wearing a `.jsonl` name.
        try fixture.compressRootRollout()
        _ = try fixture.store.moveThreadToTrash(try fixture.rootThread())
        try expect(
            !FileManager.default.fileExists(atPath: fixture.rootRollout.path + RolloutFile.compressedSuffix),
            "Trash left the compressed rollout behind"
        )
        let trashed = try require(fixture.store.loadThreadTrash().first, "Trashed thread manifest is missing")
        try fixture.store.restoreTrashedThread(trashed)
        try expect(
            FileManager.default.fileExists(atPath: fixture.rootRollout.path + RolloutFile.compressedSuffix),
            "Restore did not put the compressed rollout back under its `.zst` name"
        )
        try expect(
            !FileManager.default.fileExists(atPath: fixture.rootRollout.path),
            "Restore wrote a zstd stream to the plain `.jsonl` name"
        )
        let restored = try fixture.rootThread()
        try expect(restored.fileExists, "Restored compressed rollout is not reported as present")
        _ = try fixture.store.loadPreview(for: restored)
    }

    /// The client files chats through `thread-project-assignments`. `threads.cwd`
    /// only records where a chat was *launched* and is never rewritten when the
    /// chat is filed elsewhere, so grouping by `cwd`:
    ///
    /// - kept counting a chat in the directory it was moved out of (a real store
    ///   showed 4 chats in `~/Downloads` where the client and magpie showed 2),
    /// - hid a project entirely, because none of its chats were launched in it,
    /// - and split one project across two sidebar rows — an assigned chat grouped
    ///   under the project id, an unassigned one under the raw path.
    func testClientProjectAssignmentsDriveGrouping() throws {
        let fixture = try CodexFixture()
        defer { try? fixture.remove() }

        // The fixture files the root chat under `Source`, launched in the same
        // directory, so both resolution steps agree.
        let assigned = try fixture.rootThread()
        try expect(assigned.projectID == fixture.sourceProjectID, "An explicit assignment was ignored")
        try expect(assigned.projectName == "Source", "The client's project name was ignored")
        try expect(assigned.projectPath == fixture.sourcePath, "The project directory was not resolved")

        // Re-file the chat the way the client does — assignment only.
        try fixture.assign(threadID: fixture.rootID, to: fixture.destinationProjectID)
        try expect(
            try fixture.query("select cwd from threads where id = '\(fixture.rootID)';") == fixture.sourcePath,
            "The test did not leave the launch directory stale"
        )
        let refiled = try fixture.rootThread()
        try expect(refiled.projectID == fixture.destinationProjectID, "Grouping still followed the stale launch directory")
        try expect(refiled.projectName == "Destination", "The re-filed project name was not resolved")
        try expect(refiled.projectPath == fixture.destinationPath, "The re-filed project directory was not resolved")

        let summaries = ProjectSummary.make(from: try fixture.store.loadThreads())
        try expect(
            summaries.filter { $0.id == fixture.destinationProjectID }.count == 1,
            "The re-filed project is missing from the sidebar"
        )
        try expect(
            !summaries.contains { $0.id == fixture.sourcePath },
            "The stale launch directory is still listed as a project of its own"
        )
        let paths = summaries.map(\.path).filter { !$0.isEmpty }
        try expect(Set(paths).count == paths.count, "Two sidebar rows point at the same project directory")

        // A chat the client never filed, launched inside a project root, has to
        // join that project rather than forming a second row for the directory.
        // The fixture child is exactly that chat.
        let all = try fixture.store.loadThreads(includeSubagents: true)
        let child = try require(all.first(where: { $0.id == fixture.childID }), "Fixture child thread is missing")
        try expect(
            child.projectID == fixture.sourceProjectID,
            "An unfiled chat did not join the project owning its launch directory"
        )

        // A dangling assignment is treated as "unfiled": it must not be turned
        // into a project, and the chat falls back to the project owning its
        // launch directory.
        try fixture.assign(threadID: fixture.rootID, to: "local-does-not-exist")
        let dangling = try fixture.rootThread()
        try expect(
            dangling.project?.id != "local-does-not-exist",
            "A dangling assignment was turned into a project"
        )
        try expect(
            dangling.projectID == fixture.sourceProjectID,
            "A dangling assignment did not fall back to the launch directory's project"
        )

        // An unfiled chat whose directory no project owns falls back to the raw
        // `cwd` — the grouping the app used before projects were resolved.
        let orphanPath = fixture.home.appendingPathComponent("projects/orphan", isDirectory: true).path
        try fixture.exec("update threads set cwd = '\(orphanPath)' where id = '\(fixture.rootID)';")
        let orphan = try fixture.rootThread()
        try expect(orphan.project == nil, "An unfiled chat outside any project root produced a project")
        try expect(orphan.projectID == orphanPath, "An unfiled chat outside any project root did not fall back to cwd")
        try expect(orphan.projectPath == orphanPath, "An unfiled chat did not keep its own directory as the project path")
    }
}

private final class CodexFixture {
    let rootID = "00000000-0000-7000-8000-000000000001"
    let childID = "00000000-0000-7000-8000-000000000002"
    let sourceProjectID = "local-source"
    let destinationProjectID = "local-destination"
    let home: URL
    let sourcePath: String
    let destinationPath: String
    let rootRollout: URL
    let childRollout: URL
    let stateDB: URL
    let catalogDB: URL
    let historySnapshotsDB: URL
    let historyDB: URL
    let store: CodexStore

    /// A second chat that is never trashed. Its history rows prove that Trash
    /// scopes its deletion to the requested thread instead of emptying a table.
    let decoyID = "00000000-0000-7000-8000-000000000003"

    init() throws {
        // Deliberately rooted at `/tmp` rather than `FileManager.temporaryDirectory`.
        // On macOS `/tmp` is a symlink to `/private/tmp` and `temporaryDirectory`
        // is one to `/private/var/...`: directory enumeration always returns the
        // resolved `/private/...` form while a URL built from a string keeps the
        // unresolved form. Running the fixture through a symlinked root is what
        // reproduces that mismatch, so relative paths stay correct.
        home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("codex-keeper-tests-\(UUID().uuidString)", isDirectory: true)
        sourcePath = home.appendingPathComponent("projects/source", isDirectory: true).path
        destinationPath = home.appendingPathComponent("projects/destination", isDirectory: true).path
        rootRollout = home.appendingPathComponent("sessions/2026/08/17/root.jsonl")
        childRollout = home.appendingPathComponent("sessions/2026/08/17/child.jsonl")
        stateDB = home.appendingPathComponent("sqlite/state_5.sqlite")
        catalogDB = home.appendingPathComponent("sqlite/codex-dev.db")
        historySnapshotsDB = home.appendingPathComponent("sqlite/codex-history-snapshots-dev.db")
        historyDB = home.appendingPathComponent("sqlite/thread_history_1.sqlite")
        store = CodexStore(codexHome: home)

        try FileManager.default.createDirectory(at: stateDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootRollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
        try createDatabase()
        try createRollouts()
        try createMetadata()
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.removeItem(at: home)
        }
    }

    func query(_ sql: String) throws -> String {
        try runSQLite(sql, database: stateDB).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes to the state database, for tests that need to simulate a column the
    /// client has left stale.
    func exec(_ sql: String) throws {
        _ = try runSQLite(sql, database: stateDB)
    }

    /// The root thread, looked up by id because Branch inserts additional rows
    /// that would otherwise take over `loadThreads().first`.
    func rootThread() throws -> CodexThread {
        try require(
            store.loadThreads().first(where: { $0.id == rootID }),
            "Fixture parent thread is missing"
        )
    }

    /// Appends one raw JSONL line so a test can build a rollout with content that
    /// Trim and Branch can act on.
    func appendJSONLine(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var content = data
        content.append(Data("\n".utf8))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: content)
    }

    /// Compresses the root rollout the way Codex ages one out: the plain file is
    /// replaced by `<name>.jsonl.zst`, while `rollout_path` keeps naming the
    /// uncompressed file.
    func compressRootRollout() throws {
        let executable = try require(RolloutFile.zstdExecutable, "The zstd CLI is required to exercise compressed rollouts")
        let compressed = URL(fileURLWithPath: rootRollout.path + RolloutFile.compressedSuffix)
        if FileManager.default.fileExists(atPath: compressed.path) {
            try FileManager.default.removeItem(at: compressed)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-q", "-f", "-o", compressed.path, "--", rootRollout.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompatibilityTestFailure(description: "zstd could not compress the fixture rollout")
        }
        try FileManager.default.removeItem(at: rootRollout)
    }

    func queryCatalog(_ sql: String) throws -> String {
        try runSQLite(sql, database: catalogDB).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func queryHistorySnapshots(_ sql: String) throws -> String {
        try runSQLite(sql, database: historySnapshotsDB).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func queryHistory(_ sql: String) throws -> String {
        try runSQLite(sql, database: historyDB).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readGlobalState() throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".codex-global-state.json"))
        return try require(JSONSerialization.jsonObject(with: data) as? [String: Any], "Global state is not a JSON object")
    }

    func writeGlobalState(_ state: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: home.appendingPathComponent(".codex-global-state.json"))
    }

    /// Re-files a chat the way the client does: only the assignment changes, and
    /// `threads.cwd` keeps naming the directory the chat was launched in.
    func assign(threadID: String, to projectID: String) throws {
        var state = try readGlobalState()
        var assignments = state["thread-project-assignments"] as? [String: Any] ?? [:]
        assignments[threadID] = ["projectKind": "local", "projectId": projectID]
        state["thread-project-assignments"] = assignments
        try writeGlobalState(state)
    }

    func readJSONLMeta(at url: URL) throws -> [String: Any] {
        let first = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
        let data = try require(
            require(first, "Rollout is empty").data(using: .utf8),
            "Rollout metadata is not UTF-8"
        )
        return try require(JSONSerialization.jsonObject(with: data) as? [String: Any], "Rollout metadata is not a JSON object")
    }

    private func createDatabase() throws {
        let schema = """
        create table threads (
            id text primary key, rollout_path text not null, created_at integer not null,
            updated_at integer not null, source text not null, model_provider text not null,
            cwd text not null, title text not null, sandbox_policy text not null,
            approval_mode text not null, tokens_used integer not null default 0,
            has_user_event integer not null default 0, archived integer not null default 0,
            archived_at integer, git_sha text, git_branch text, git_origin_url text,
            cli_version text not null default '', first_user_message text not null default '',
            agent_nickname text, agent_role text, memory_mode text not null default 'enabled',
            model text, reasoning_effort text, agent_path text, created_at_ms integer,
            updated_at_ms integer, thread_source text, preview text not null default '',
            recency_at integer not null default 0, recency_at_ms integer not null default 0,
            history_mode text not null default 'legacy', name text, is_pinned integer not null default 0,
            thread_section_id text, section_position integer, section_entered_at_ms integer
        );
        create table thread_spawn_edges (
            parent_thread_id text not null, child_thread_id text not null primary key, status text not null
        );
        create table thread_dynamic_tools (
            thread_id text not null, position integer not null, name text not null,
            description text not null, input_schema text not null,
            defer_loading integer not null default 0, namespace text,
            primary key(thread_id, position)
        );
        create table thread_attachments (
            id text primary key, thread_id text not null, attachment_type text not null,
            identity_key text not null, payload text not null, created_at integer not null
        );
        insert into threads values (
            '\(rootID)', '\(sql(rootRollout.path))', 100, 200, 'vscode', 'openai',
            '\(sql(sourcePath))', 'Root', '{}', 'never', 10, 1, 0, null,
            null, null, null, '1.0', 'Root message', null, null, 'enabled',
            'gpt-test', 'high', null, 100000, 200000, 'user', 'Root preview',
            150, 150000, 'legacy', 'Pinned root', 1, 'section-1', 2, 160000
        );
        insert into threads values (
            '\(childID)', '\(sql(childRollout.path))', 110, 190,
            '\(sql("{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(rootID)\",\"depth\":1}}}"))',
            'openai', '\(sql(sourcePath))', 'Child', '{}', 'never', 5, 0, 0, null,
            null, null, null, '1.0', '', 'Scout', 'research-worker', 'enabled',
            'gpt-test', 'low', '/root/scout', 110000, 190000, 'subagent', '',
            140, 140000, 'legacy', null, 0, null, null, null
        );
        insert into thread_spawn_edges values ('\(rootID)', '\(childID)', 'open');
        insert into thread_dynamic_tools values ('\(rootID)', 0, 'fixture', 'Fixture tool', '{}', 0, 'tests');
        insert into thread_attachments values ('attachment-1', '\(rootID)', 'file', 'key-1', '{"fixture":true}', 1700000000);
        """
        _ = try runSQLite(schema, database: stateDB)
        _ = try runSQLite(
            "create table local_thread_catalog (thread_id text primary key, display_title text); " +
            "insert into local_thread_catalog values ('\(rootID)', 'Catalog root'); " +
            "create table local_thread_catalog_metadata (id integer primary key, catalog_revision integer); " +
            "insert into local_thread_catalog_metadata values (1, 4);",
            database: catalogDB
        )
        _ = try runSQLite(
            "create table app_server_history_snapshots (thread_id text primary key, payload_json text); " +
            "insert into app_server_history_snapshots values ('\(rootID)', '{\"fixture\":true}');",
            database: historySnapshotsDB
        )
        // Codex moved chat transcripts out of `codex-history-snapshots-dev.db` into
        // `thread_history_<N>.sqlite`. Trash and Restore must reach it.
        _ = try runSQLite(
            "create table thread_items (thread_id text, turn_id text, item_id text, item_json text, " +
            "primary key(thread_id, turn_id, item_id)); " +
            "create table thread_turns (thread_id text, turn_id text, status text, primary key(thread_id, turn_id)); " +
            "create table thread_history_projection_state (thread_id text primary key, next_rollout_byte_offset integer); " +
            "insert into thread_items values ('\(rootID)', 'turn-1', 'item-1', '{\"fixture\":1}'); " +
            "insert into thread_items values ('\(rootID)', 'turn-1', 'item-2', '{\"fixture\":2}'); " +
            "insert into thread_items values ('\(decoyID)', 'turn-9', 'item-9', '{\"decoy\":1}'); " +
            "insert into thread_turns values ('\(rootID)', 'turn-1', 'done'); " +
            "insert into thread_turns values ('\(decoyID)', 'turn-9', 'done'); " +
            "insert into thread_history_projection_state values ('\(rootID)', 4096); " +
            "insert into thread_history_projection_state values ('\(decoyID)', 8192);",
            database: historyDB
        )
    }

    private func createRollouts() throws {
        let rootMeta: [String: Any] = [
            "type": "session_meta",
            "timestamp": "2026-08-17T00:00:00Z",
            "payload": ["id": rootID, "cwd": sourcePath, "thread_source": "user"]
        ]
        let childMeta: [String: Any] = [
            "type": "session_meta",
            "timestamp": "2026-08-17T00:00:00Z",
            "payload": [
                "id": childID,
                "cwd": sourcePath,
                "thread_source": "subagent",
                "source": ["subagent": ["thread_spawn": ["parent_thread_id": rootID, "depth": 1]]]
            ]
        ]
        try writeJSONLine(rootMeta, to: rootRollout)
        try writeJSONLine(childMeta, to: childRollout)
    }

    private func createMetadata() throws {
        let index = "{\"id\":\"\(rootID)\",\"thread_name\":\"Root\",\"updated_at\":\"2026-08-17T00:00:00Z\"}\n"
        try Data(index.utf8).write(to: home.appendingPathComponent("session_index.jsonl"))
        let state: [String: Any] = [
            "local-projects": [
                sourceProjectID: ["id": sourceProjectID, "name": "Source", "rootPaths": [sourcePath]],
                destinationProjectID: ["id": destinationProjectID, "name": "Destination", "rootPaths": [destinationPath]]
            ],
            "thread-project-assignments": [rootID: ["projectKind": "local", "projectId": sourceProjectID]],
            "sidebar-project-thread-orders": [
                sourceProjectID: ["threadIds": [rootID]],
                destinationProjectID: ["threadIds": []]
            ],
            "projectless-thread-ids": [],
            "thread-workspace-root-hints": [:],
            "thread-projectless-output-directories": [:]
        ]
        try writeGlobalState(state)
    }

    private func writeJSONLine(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var content = data
        content.append(Data("\n".utf8))
        try content.write(to: url)
    }

    private func runSQLite(_ sql: String, database: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CodexFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private struct CompatibilityTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CompatibilityTestFailure(description: message) }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CompatibilityTestFailure(description: message) }
    return value
}
