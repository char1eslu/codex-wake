import Foundation
import CodexKeeperCore

@main
private struct CompatibilityTestRunner {
    static func main() throws {
        let suite = CodexStoreCompatibilityTests()
        try suite.testSubagentsAreFoldedIntoParentAndNeverListedForRepair()
        try suite.testMoveUpdatesSQLiteRolloutAndNativeProjectMetadata()
        try suite.testTrashAndRestorePreserveCurrentMetadataAndRelations()
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
        try expect(try fixture.queryCatalog("select count(*) from local_thread_catalog where thread_id = '\(fixture.rootID)';") == "0", "Catalog row remains after trash")
        try expect(try fixture.queryCatalog("select catalog_revision from local_thread_catalog_metadata where id = 1;") == "5", "Catalog revision was not advanced after trash")
        try expect(try fixture.queryHistorySnapshots("select count(*) from app_server_history_snapshots where thread_id = '\(fixture.rootID)';") == "0", "History snapshot remains after trash")
        try expect(!FileManager.default.fileExists(atPath: fixture.rootRollout.path), "Rollout remains after trash")
        let removedState = try fixture.readGlobalState()
        try expect((removedState["thread-project-assignments"] as? [String: Any])?[fixture.rootID] == nil, "Global assignment remains after trash")

        let trashed = try require(fixture.store.loadThreadTrash().first, "Trashed thread manifest is missing")
        try fixture.store.restoreTrashedThread(trashed)

        try expect(FileManager.default.fileExists(atPath: fixture.rootRollout.path), "Rollout was not restored")
        try expect(try fixture.query("select name || '|' || is_pinned || '|' || history_mode from threads where id = '\(fixture.rootID)';") == "Pinned root|1|legacy", "Current thread metadata was not restored")
        try expect(try fixture.query("select count(*) from thread_dynamic_tools where thread_id = '\(fixture.rootID)';") == "1", "Dynamic tools were not restored")
        try expect(try fixture.query("select status from thread_spawn_edges where parent_thread_id = '\(fixture.rootID)';") == "open", "Spawn edge was not restored")
        try expect(try fixture.queryCatalog("select display_title from local_thread_catalog where thread_id = '\(fixture.rootID)';") == "Catalog root", "Catalog row was not restored")
        try expect(try fixture.queryCatalog("select catalog_revision from local_thread_catalog_metadata where id = 1;") == "6", "Catalog revision was not advanced after restore")
        try expect(try fixture.queryHistorySnapshots("select payload_json from app_server_history_snapshots where thread_id = '\(fixture.rootID)';") == "{\"fixture\":true}", "History snapshot was not restored")
        let restoredState = try fixture.readGlobalState()
        let assignment = (restoredState["thread-project-assignments"] as? [String: Any])?[fixture.rootID] as? [String: Any]
        try expect(assignment?["projectId"] as? String == fixture.sourceProjectID, "Native project assignment was not restored")
        try expect(try fixture.store.loadThreads().first?.childThreadCount == 1, "Restored parent lost its child count")
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
    let store: CodexStore

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-keeper-tests-\(UUID().uuidString)", isDirectory: true)
        sourcePath = home.appendingPathComponent("projects/source", isDirectory: true).path
        destinationPath = home.appendingPathComponent("projects/destination", isDirectory: true).path
        rootRollout = home.appendingPathComponent("sessions/2026/08/17/root.jsonl")
        childRollout = home.appendingPathComponent("sessions/2026/08/17/child.jsonl")
        stateDB = home.appendingPathComponent("sqlite/state_5.sqlite")
        catalogDB = home.appendingPathComponent("sqlite/codex-dev.db")
        historySnapshotsDB = home.appendingPathComponent("sqlite/codex-history-snapshots-dev.db")
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

    func queryCatalog(_ sql: String) throws -> String {
        try runSQLite(sql, database: catalogDB).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func queryHistorySnapshots(_ sql: String) throws -> String {
        try runSQLite(sql, database: historySnapshotsDB).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readGlobalState() throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".codex-global-state.json"))
        return try require(JSONSerialization.jsonObject(with: data) as? [String: Any], "Global state is not a JSON object")
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
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: home.appendingPathComponent(".codex-global-state.json"))
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
