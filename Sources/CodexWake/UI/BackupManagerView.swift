import SwiftUI

struct BackupManagerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingTrashSelected = false
    @State private var isConfirmingTrashAll = false
    @State private var isConfirmingRestore = false
    @State private var isConfirmingEmptyTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if model.isLoadingBackups && model.backups.isEmpty {
                ProgressView("Scanning backups...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.backups.isEmpty {
                ContentUnavailableView("No backups found", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                backupList
            }

            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .liquidGlassBackground
        .task {
            await model.refreshBackups()
        }
        .alert("Move selected backups to trash?", isPresented: $isConfirmingTrashSelected) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.deleteSelectedBackups() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.selectedBackupIDs.count) backup files will be moved to Codex Wake trash.")
        }
        .alert("Move all backups to trash?", isPresented: $isConfirmingTrashAll) {
            Button("Move All", role: .destructive) {
                Task { await model.deleteAllBackups() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.backups.count) backup files using \(model.backupSizeLabel) will be moved to Codex Wake trash.")
        }
        .alert("Restore selected chat backup?", isPresented: $isConfirmingRestore) {
            Button("Restore", role: .destructive) {
                Task { await model.restoreSelectedBackup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current chat JSONL file will be replaced by this backup. The backup file will stay in Backups.")
        }
        .alert("Empty backup trash?", isPresented: $isConfirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) {
                Task { await model.emptyBackupTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.backupTrash.count) backup files will be permanently deleted from Codex Wake trash.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backups")
                    .font(.title3.weight(.semibold))
                Text("\(model.backups.count) files · \(model.backupSizeLabel) · Trash \(model.backupTrash.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await model.refreshBackups() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .liquidGlassButtonStyle()
            .disabled(model.isLoadingBackups)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .liquidGlassButtonStyle()
            .help("Close")
        }
        .padding(16)
        .liquidGlassContainer(spacing: 10)
    }

    private var backupList: some View {
        Table(model.backups, selection: $model.selectedBackupIDs) {
            TableColumn("Original") { backup in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: backup.kind.systemImage)
                            .foregroundStyle(.secondary)
                        Text(backup.chatTitle ?? backup.originalName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    Text(backup.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(backup.directory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 260, ideal: 320)

            TableColumn("Backup Time") { backup in
                Text(backup.stamp)
                    .font(.caption.monospaced())
            }
            .width(150)

            TableColumn("Modified") { backup in
                Text(WakeDates.display(backup.modifiedAt))
                    .font(.caption)
            }
            .width(150)

            TableColumn("Size") { backup in
                Text(backup.sizeLabel)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
        }
        .contextMenu {
            Button {
                model.revealSelectedBackupsInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(model.selectedBackupIDs.isEmpty || model.isDemoMode)

            Button {
                model.copySelectedBackupPaths()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            .disabled(model.selectedBackupIDs.isEmpty)

            Button {
                isConfirmingRestore = true
            } label: {
                Label("Restore Chat Backup", systemImage: "arrow.counterclockwise")
            }
            .disabled(!canRestoreSelectedBackup)

            Divider()

            Button(role: .destructive) {
                isConfirmingTrashSelected = true
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(model.selectedBackupIDs.isEmpty)
        }
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.selectedBackupIDs.isEmpty {
                Text("Select backups to reveal, copy, restore, or move to trash.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.selectedBackupIDs.count) selected · \(model.selectedBackupSizeLabel)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.revealSelectedBackupsInFinder()
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(model.selectedBackupIDs.isEmpty || model.isDemoMode)

            Button {
                model.copySelectedBackupPaths()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            .disabled(model.selectedBackupIDs.isEmpty)

            Button {
                isConfirmingRestore = true
            } label: {
                Label("Restore", systemImage: "arrow.counterclockwise")
            }
            .disabled(!canRestoreSelectedBackup || model.isLoadingBackups)

            Button(role: .destructive) {
                isConfirmingTrashSelected = true
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(model.selectedBackupIDs.isEmpty || model.isLoadingBackups)

            Button(role: .destructive) {
                isConfirmingTrashAll = true
            } label: {
                Label("Trash All", systemImage: "trash")
            }
            .disabled(model.backups.isEmpty || model.isLoadingBackups)

            Button(role: .destructive) {
                isConfirmingEmptyTrash = true
            } label: {
                Label("Empty Trash", systemImage: "trash.slash")
            }
            .disabled(model.backupTrash.isEmpty || model.isLoadingBackups)
        }
        .font(.caption)
        .padding(12)
        .liquidGlassContainer(spacing: 10)
    }

    private var canRestoreSelectedBackup: Bool {
        model.selectedBackups.count == 1 && model.selectedBackups.first?.kind == .chatFile
    }
}
