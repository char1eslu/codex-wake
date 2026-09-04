# Codex Keeper

Codex Keeper is the new name for Codex Wake. The GitHub repository is still named `codex-wake` during the transition so existing links, releases, and local checkouts continue to work.

Codex Keeper is a local macOS app for finding, previewing, repairing, moving, trimming, branching, trashing, restoring, and backing up Codex Desktop chat sessions — and now **Claude Code / Claude Desktop sessions** too.

This fork keeps the app as a dense **Liquid Glass** desktop utility while pulling in the newer session-management features from upstream.

![Codex Keeper screenshot](assets/screenshot.png)

## Claude Session Support

Use the **Codex ⌘ / Claude ✦** toggle at the top of the sidebar to switch between Codex and Claude sources. Both backends share the same three-pane UI.

For Claude sessions (`~/.claude/projects/**/*.jsonl`), Codex Keeper supports:

- Browse sessions grouped by project, search by title/preview/path, and full-chat preview (thinking blocks shown as `[thinking]`, tool calls as `[tool: name]`; subagent sidechains are hidden).
- Titles come from the session's `custom-title` line, falling back to the first user message.
- **Move between projects**: rewrites every `cwd` field inside the JSONL, relocates the file to the target project directory using Claude's exact directory encoding (every non-alphanumeric character becomes `-`), and syncs Claude Desktop's own session index (`~/Library/Application Support/Claude-3p/claude-code-sessions/*/local_*.json`) so the chat shows up in the Desktop sidebar under the new project.
- **Trash / restore** with per-session manifests under `~/.claude/.claude-keeper-trash`, plus a separate backup trail marked `.claude-rescue-backup-`.
- Live-session protection: sessions currently open in a running Claude Code/Desktop client are detected via `~/.claude/sessions/*.json` and refused for move/trash, because the running client would recreate the file at its old path.
- Sessions that only exist as CLI files (no Desktop index entry) get a new index entry created on move, titled from the chat content.
- Repair Index / Trim / Branch are Codex-only operations and are disabled for Claude sessions.

## What This Version Adds

- Renamed the app from **Codex Wake** to **Codex Keeper**.
- Added the new Codex Keeper app icon.
- Kept the repository name `codex-wake`, bundle id `app.codexwake.CodexWake`, executable name `CodexWake`, and legacy `.codex-wake-trash` storage path for compatibility.
- Liquid Glass three-pane UI for projects, chats, and detail preview.
- Compact search field with an inline icon-only **Deep Search** action.
- Multi-select chat actions with shift/command selection, context menus, keyboard navigation, and batch repair/move/trash.
- Codex subagent threads are folded into their parent chat instead of appearing as independent chats or repair candidates.
- `Not indexed` session state when a chat exists in `~/.codex/sqlite/state_5.sqlite` but is missing from `session_index.jsonl`.
- **Repair Index** adds missing `session_index.jsonl` entries for chats that need metadata repair.
- Safe **Move to Trash** support for chats, including selected chats.
- Backup Manager **Trash** tab with trashed chat restore and permanent delete actions.
- Full-chat preview with turn-aware **Trim from here** and **Branch from here** controls.
- Backup Manager with chat-backup restore, move-to-trash, and empty-trash actions.
- Bundled `codex-keeper` CLI with `doctor`, chat/project/backup inspection, JSON output, and wake dry-runs.
- App menu actions for installing or uninstalling the bundled CLI without changing the app itself.
- Refresh no longer blocks on backup scans or preview parsing, reducing stuck global spinner cases.
- SwiftPM macOS run workflow with `script/build_and_run.sh` and a Codex Run action.
- Local `.app` bundle builds are ad-hoc signed for stricter local codesign validation.
- The main window opens at `1200x890` points and keeps the detail action bar on one line.
- Refreshed README screenshot for the Codex Keeper layout.

## Core Features

- Browse local Codex chats grouped by project.
- Search by title, first message, preview text, path, or thread id.
- Run deep search inside JSONL chat files when metadata search is not enough.
- Preview chat messages without opening Codex Desktop.
- Repair missing session-index entries so Codex Desktop can see unindexed chats again.
- Move chats between known project folders by updating SQLite, rollout metadata, and Codex Desktop's native project/sidebar assignments together.
- Move chats to Codex Keeper Trash by removing current Codex metadata and moving the JSONL file into app trash when it exists; restore reinstates project, spawn-edge, dynamic-tool, catalog, and history-snapshot records.
- Trim a chat from a selected user message, with a backup created first.
- Branch a new chat from an earlier Codex turn without changing the original.
- Reveal chat JSONL files in Finder or copy their paths.
- Use the `codex-keeper` CLI for terminal workflows and automation-safe JSON output.

## Compatibility Boundary

Codex Keeper is a local storage and transcript utility. It reads current Codex thread metadata, parent/child relationships, rollout files, and sidebar state, and it can repair or reorganize those files with backups. It does not act as a Codex app-server client: creating/resuming live turns, steering or interrupting a running thread, and server-mediated archive/rename operations remain outside the supported surface.

## UI Notes

The interface is intentionally work-focused:

- Project sidebar shows per-project total, available, and repair-needed counts.
- Chat rows show title, project path, update time, and status.
- `Not indexed` means the session row exists in SQLite but the session-index entry is missing.
- The search field owns both normal metadata search and inline deep search.
- Detail preview keeps message cards readable and exposes trim/branch controls at user-message boundaries.
- Detail actions stay right-aligned as a single row: **Repair Index**, **Move**, **Reveal**, **Trash**, and **Copy Path**.
- Backup management stays in a Liquid Glass sheet instead of replacing the main navigation layout.

## Data It Reads

Codex Keeper reads local Codex Desktop files:

```text
~/.codex/sqlite/state_5.sqlite
~/.codex/sqlite/codex-dev.db
~/.codex/sqlite/codex-history-snapshots-dev.db
~/.codex/.codex-global-state.json
~/.codex/session_index.jsonl
~/.codex/sessions/**/*.jsonl
```

For Claude sessions it reads and manages:

```text
~/.claude/projects/**/*.jsonl
~/.claude/sessions/*.json                  (live-session detection)
~/Library/Application Support/Claude-3p/claude-code-sessions/  (Desktop sidebar index)
```

The app has no server component and does not send chat content anywhere.

## Repair Index Operation

When you repair a selected not-indexed chat, Codex Keeper creates backups and updates the local metadata Codex Desktop uses for sidebar visibility:

- `threads.thread_source = 'user'`
- `threads.updated_at` and `threads.updated_at_ms`
- `session_index.jsonl.updated_at`
- the first `session_meta` JSONL line: `timestamp` and `payload.timestamp`

If the chat is missing from `session_index.jsonl`, Codex Keeper appends a new index line using the existing chat title. The chat messages themselves are not changed by repair.

Backups are written next to the original files with `.codex-rescue-backup-<timestamp>` suffixes.

## Trim And Branch

**Trim from here** creates a backup of the selected chat JSONL file, then removes the selected user message and everything after it. The first visible user message cannot be trimmed because Codex stores it as preview metadata.

**Branch from here** creates a new chat using the conversation history before the selected Codex turn. The original chat is not changed. Codex Keeper creates safety backups for local state files before registering the new branch.

## Backups And Trash

The Backup Manager lists Codex Keeper backup files with original path, size, kind, creation time, and inferred chat title where possible.

Chat file backups can be restored from the Backup Manager. Restoring replaces the current chat JSONL file with the selected restore point. The selected backup remains available.

Chat files and backup files are moved to Codex Keeper's app trash before permanent deletion. The on-disk folder remains `~/.codex/.codex-wake-trash` for compatibility with existing Codex Wake backups. Trashed chats can be restored from the Backup Manager **Trash** tab. **Empty Trash** permanently deletes files from that app trash.

## Demo Mode

Demo mode uses synthetic projects and chats and does not read or write `~/.codex`.

```sh
open -n "dist/Codex Keeper.app" --args --demo
```

You can also launch it with:

```sh
CODEX_WAKE_DEMO=1 "dist/Codex Keeper.app/Contents/MacOS/CodexWake"
```

## Command Line Tool

Codex Keeper bundles a `codex-keeper` CLI inside the app.

After installing the app, open the **Codex Keeper** app menu and choose **Install Command Line Tool...**. The app copies the bundled CLI to:

```text
~/.local/bin/codex-keeper
```

To remove the terminal command later, choose **Uninstall Command Line Tool...** from the same app menu. This only removes the copy in `~/.local/bin`; the Codex Keeper app and its bundled CLI remain unchanged.

If your shell cannot find `codex-keeper`, make sure `~/.local/bin` is on your `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Useful read-only commands:

```sh
codex-keeper doctor
codex-keeper chats list --limit 20
codex-keeper chats search "release plan" --deep --json
codex-keeper chats show <thread-id-or-prefix>
codex-keeper projects list --json
codex-keeper backups list --limit 20 --json
```

Preview a repair/wake operation without writing files:

```sh
codex-keeper chats wake <thread-id-or-prefix> --dry-run
codex-keeper chats wake <thread-id-or-prefix> --dry-run --json
```

Run the actual repair/wake operation only after reviewing the dry-run output:

```sh
codex-keeper chats wake <thread-id-or-prefix>
```

## Build And Run

Requirements:

- macOS 14 or newer
- Swift 6 toolchain

Build the executable:

```sh
swift build
```

Run the isolated current-schema compatibility suite:

```sh
swift run CodexKeeperCompatibilityTests
```

Build only the CLI:

```sh
swift build --product codex-keeper
```

Build a local `.app` bundle:

```sh
./scripts/build-app.sh
```

The app bundle includes the `codex-keeper` CLI so the app menu can install and uninstall the terminal command.

Run the app through the macOS development entrypoint:

```sh
./script/build_and_run.sh
```

Verify that the app builds, launches, and has a running process:

```sh
./script/build_and_run.sh --verify
```

Stream process logs:

```sh
./script/build_and_run.sh --logs
```

The app bundle is written to:

```text
dist/Codex Keeper.app
```

Local bundles are ad-hoc signed so `codesign --verify --deep --strict` can validate the staged app. This is suitable for local testing. It is not Developer ID signing or notarization.

## Window Layout

The main window is sized for the three-pane desktop workflow:

- default opening size: `1200x890` points
- minimum size: `1120x720` points
- detail actions are kept on one line and aligned close to the right edge

The app sets the window size at launch through a narrow AppKit bridge so macOS window restoration does not reopen an old, cramped size by accident. You can still resize the window after it opens.

## Safety Notes

Codex Keeper edits local Codex metadata when you press **Repair Index**, **Move**, **Move to Trash**, **Trim from here**, **Branch from here**, or **Restore**.

Keep Codex Desktop closed while changing old threads if you want to avoid concurrent writes.

If something looks wrong after an operation, restore the relevant backup from the Backup Manager. Do not empty app trash until you are sure you no longer need those backups.

## Status

Early local utility. Compatibility-tested with Codex Desktop 26.810 storage and isolated fixtures, but Codex storage is private and can change.

## Disclaimer

Codex Keeper is unofficial and is not affiliated with OpenAI.

## License

MIT
