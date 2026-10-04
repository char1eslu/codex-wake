# Changelog

All notable changes to Codex Keeper, formerly Codex Wake, are documented here.

## Unreleased

### Fixed

- **State database discovery is no longer hardcoded to `state_5.sqlite`.** Codex Keeper now picks the highest-version database in `~/.codex/sqlite/` (and `~/.codex`) that actually contains a `threads` table, falling back to the newest candidate. A Codex release that bumps the file name previously made the whole app report "state database not found".
- **Repair Index works again for chats without the `has_user_event` flag.** Older Codex builds wrote `has_user_event = 0` for chats that do contain messages, so the eligibility guard rejected every real chat. Repair now requires conversation content (a stored first user message or preview) instead of that flag, and still refuses subagent chats.
- **Trash and Restore cover every database that references a chat.** The set of sibling databases is discovered by scanning for `*.sqlite`/`*.db` instead of a hardcoded pair, which restores coverage of `thread_history_<N>.sqlite` — Codex moved chat transcripts there and trashing a chat had been leaving the transcript rows orphaned with no way to restore them.
- **Trash and Restore are now symmetric for state-database tables.** Deletion already discovered referencing tables from the live schema; restore did not, so trashing a chat removed its `thread_attachments` rows permanently. Restore now reinstates every discovered row set from the manifest.
- **Relative paths are computed from canonicalised URLs.** Directory enumeration returns fully resolved paths while a URL built from a string does not, so trashing a chat could target a file that does not exist and silently skip it. Base URLs are now symlink-resolved once at construction, and relative paths resolve both sides.
- **Large history databases are no longer copied in full.** A database above 64 MiB is restored from its row snapshot rather than a full-file copy, so trashing one chat no longer writes and retains a copy of a multi-hundred-megabyte transcript.
- **The app builds again on machines without Xcode.** The macOS 27 SDK turned SwiftUI's `@State` into a macro backed by the `SwiftUIMacros` host plugin, which ships only with Xcode; the default SDK therefore failed with `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`. Both build scripts now fall back to the newest installed SDK that does not require the plugin (the macOS 26 SDK still declares `@State` as a plain property wrapper). Nothing changes when Xcode is present.
- `scripts/build-app.sh` derived its build output directory from `.build/<configuration>`, which no longer matches where SwiftPM places products; it now asks SwiftPM via `--show-bin-path`.

### Added

- **Codex live-session protection.** Chats currently open in Codex Desktop are detected through `~/.codex/thread-writer-locks/*.lock` and refused for move and trash, matching the existing Claude live-session guard.
- **`--claude` / `--claude-home` for the `codex-keeper` CLI.** `doctor`, `chats`, and `projects` can now inspect Claude Code / Claude Desktop sessions. `chats wake --claude` is refused with an explanatory error because Repair Index is Codex-only.
- **`./script/build_and_run.sh build`** stages the `.app` bundle without launching it.
- `script/select-sdk.sh` picks a buildable SDK when the `SwiftUIMacros` plugin is unavailable, so the app still builds on a Command Line Tools-only machine. Override with `CODEX_KEEPER_SDK`.
- SQLite busy timeouts on chat deletion and restore, so a brief writer lock from Codex no longer fails the whole operation.

### Changed

- `BackupKind.label` for the state database is now `Database` instead of `State DB`.

## 0.2.1 - 2026-08-17

- Updated chat discovery for Codex Desktop 26.810 and hide subagent threads from the user-facing chat list while retaining their count on the parent chat.
- Prevented subagent threads from being repaired, moved, or deleted independently from their parent.
- Fixed project moves by synchronizing `threads.cwd`, rollout `session_meta.payload.cwd`, native project assignments, and sidebar ordering.
- Updated Trash and restore for current thread columns, spawn edges, dynamic tools, native project state, catalog rows, and history snapshots.
- Added atomic rollback paths, consistent SQLite snapshots, and isolated current-schema compatibility tests.

## 0.2.0 - 2026-06-12

- Renamed the app from **Codex Wake** to **Codex Keeper**.
- Added the new Codex Keeper app icon.
- Updated the app bundle name, sidebar title, window title, README, release copy, and user-facing maintenance messages.
- Kept the repository name `codex-wake`, bundle identifier `app.codexwake.CodexWake`, executable name `CodexWake`, and legacy `.codex-wake-trash` storage path for compatibility.
- Positioned the app as a local Codex chat maintenance tool while preserving existing backup, trash, repair, trim, branch, and restore workflows.
- Set the default main-window size to `1200x890` and keep detail action buttons visible on one line.
- Refreshed the README screenshot for the new Codex Keeper layout.

## 0.1.6 - 2026-06-12

- Updated chat availability behavior for Codex app 26.609, which now shows older chats directly in the sidebar.
- Replaced the primary wake workflow with **Repair Index** for chats missing from `session_index.jsonl`.
- Added safe **Move to Trash** support for chats, including selected chats.
- Added trashed chat restore and permanent delete actions in the Backup Manager **Trash** tab.
- Missing chat files can now be cleaned from Codex metadata by moving them to Codex Keeper Trash.
- Added optional `CODEX_WAKE_SCRATCH_PATH` support to the app build script for clean Swift builds.

## 0.1.5 - 2026-06-06

- Fixed a SwiftUI list layout busy loop triggered by long, multi-line chat metadata.
- Normalized loaded chat metadata to bounded one-line strings before rendering.

## 0.1.4 - 2026-06-05

- Added **Trim from here** for cutting a local chat back to an earlier user message, with a backup created first.
- Added **Branch from here** for creating a new chat from an earlier Codex turn without changing the original.
- Added chat backup restore from the Backup Manager.
- Improved full-chat preview loading and turn-aware branch points.
- Added adaptive dark mode colors.

## 0.1.3 - 2026-05-31

- Improved chat title and visibility status detection using `session_index.jsonl`.
- Added multi-select mode for chat actions.
- Added batch **Wake** for selected chats, with confirmation.
- Added context menu actions for chat rows.
- Added Backup Manager for viewing backup files created by Codex Wake.
- Added app trash for backup files, with a separate **Trash** section and confirmed permanent cleanup.
- Improved wake feedback and 7-day visibility handling.

## 0.1.2 - 2026-05-31

- Improved chat preview readability.
- Hid noisy technical instruction blocks from previews.
- Improved project sorting and chat sorting.
- Added created and last-message dates to chat rows.
- Prepared signed and notarized macOS release build.

## 0.1.1 - 2026-05-26

- Added screenshot-safe demo mode with synthetic projects and chats.
- Added project move support for moving chats between known project folders.
- Updated README screenshot.
- Updated app icon and release build packaging.

## 0.1.0 - 2026-05-25

- Initial public release.
- Browsed local Codex chat threads grouped by project.
- Added metadata search and optional deep search through JSONL transcripts.
- Added chat preview.
- Added **Wake** operation for making hidden older chats appear again in the Codex sidebar.
- Added backup creation before metadata changes.
- Added Finder reveal and copy-path actions.
