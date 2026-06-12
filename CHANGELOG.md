# Changelog

All notable changes to Codex Keeper, formerly Codex Wake, are documented here.

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
