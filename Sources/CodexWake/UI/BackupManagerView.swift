import SwiftUI
import CodexKeeperCore

struct BackupManagerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: BackupManagerTab = .backups
    @State private var isConfirmingTrashSelected = false
    @State private var isConfirmingTrashAll = false
    @State private var isConfirmingRestore = false
    @State private var isConfirmingRestoreTrashThread = false
    @State private var isConfirmingDeleteTrashThreads = false
    @State private var isConfirmingEmptyTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Picker("Backup view", selection: $selectedTab) {
                ForEach(BackupManagerTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if model.isLoadingBackups && model.backups.isEmpty && model.trashItemCount == 0 {
                ProgressView("Scanning backups...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch selectedTab {
                case .backups:
                    if model.backups.isEmpty {
                        ContentUnavailableView("No backups found", systemImage: "archivebox")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        backupList
                    }
                case .trash:
                    if model.trashItemCount == 0 {
                        ContentUnavailableView("Trash is empty", systemImage: "trash")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        trashList
                    }
                }
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
            Text("\(model.selectedBackupIDs.count) backup files will be moved to Codex Keeper trash.")
        }
        .alert("Move all backups to trash?", isPresented: $isConfirmingTrashAll) {
            Button("Move All", role: .destructive) {
                Task { await model.deleteAllBackups() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.backups.count) backup files using \(model.backupSizeLabel) will be moved to Codex Keeper trash.")
        }
        .alert("Restore selected chat backup?", isPresented: $isConfirmingRestore) {
            Button("Restore", role: .destructive) {
                Task { await model.restoreSelectedBackup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current chat JSONL file will be replaced by this backup. The backup file will stay in Backups.")
        }
        .alert("Restore trashed chat?", isPresented: $isConfirmingRestoreTrashThread) {
            Button("Restore", role: .destructive) {
                Task { await model.restoreSelectedTrashThread() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The chat file and Codex metadata will be restored from Codex Keeper Trash.")
        }
        .alert("Delete trashed chats permanently?", isPresented: $isConfirmingDeleteTrashThreads) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelectedTrashThreadsPermanently() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.selectedTrashThreadIDs.count) trashed chats will be permanently deleted from Codex Keeper Trash.")
        }
        .alert("Empty trash?", isPresented: $isConfirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) {
                Task { await model.emptyBackupTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.threadTrash.count) trashed chats and \(model.backupTrash.count) backup files will be permanently deleted from Codex Keeper Trash.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backups")
                    .font(.title3.weight(.semibold))
                Text("\(model.backups.count) backups · \(model.backupSizeLabel) · Trash \(model.trashItemCount) · \(model.trashSizeLabel)")
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

    private var trashList: some View {
        VStack(spacing: 0) {
            if !model.threadTrash.isEmpty {
                Text("Chats")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                Table(model.threadTrash, selection: $model.selectedTrashThreadIDs) {
                    TableColumn("Title") { thread in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: "text.bubble")
                                    .foregroundStyle(.secondary)
                                Text(thread.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                            Text(thread.cwd)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .width(min: 280, ideal: 360)

                    TableColumn("Trashed") { thread in
                        Text(WakeDates.display(thread.trashedAt))
                            .font(.caption)
                    }
                    .width(150)

                    TableColumn("Size") { thread in
                        Text(thread.sizeLabel)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(80)
                }
                .frame(minHeight: 150)
                .contextMenu {
                    Button {
                        model.revealSelectedTrashThreadsInFinder()
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .disabled(model.selectedTrashThreadIDs.isEmpty || model.isDemoMode)

                    Button {
                        model.copySelectedTrashThreadPaths()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .disabled(model.selectedTrashThreadIDs.isEmpty)

                    Button {
                        isConfirmingRestoreTrashThread = true
                    } label: {
                        Label("Restore Chat", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(model.selectedTrashThreads.count != 1)

                    Divider()

                    Button(role: .destructive) {
                        isConfirmingDeleteTrashThreads = true
                    } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                    .disabled(model.selectedTrashThreadIDs.isEmpty)
                }
                .scrollContentBackground(.hidden)
            }

            if !model.backupTrash.isEmpty {
                Text("Backup Files")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                Table(model.backupTrash, selection: $model.selectedTrashBackupIDs) {
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
                    .width(min: 280, ideal: 360)

                    TableColumn("Backup Time") { backup in
                        Text(backup.stamp)
                            .font(.caption.monospaced())
                    }
                    .width(150)

                    TableColumn("Size") { backup in
                        Text(backup.sizeLabel)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(80)
                }
                .frame(minHeight: 150)
                .contextMenu {
                    Button {
                        model.revealSelectedTrashBackupsInFinder()
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .disabled(model.selectedTrashBackupIDs.isEmpty || model.isDemoMode)

                    Button {
                        model.copySelectedTrashBackupPaths()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .disabled(model.selectedTrashBackupIDs.isEmpty)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch selectedTab {
            case .backups:
                backupFooter
            case .trash:
                trashFooter
            }
        }
        .font(.caption)
        .padding(12)
        .liquidGlassContainer(spacing: 10)
    }

    @ViewBuilder
    private var backupFooter: some View {
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
    }

    @ViewBuilder
    private var trashFooter: some View {
        let threadCount = model.selectedTrashThreadIDs.count
        let backupCount = model.selectedTrashBackupIDs.count
        if threadCount == 0 && backupCount == 0 {
            Text("Select trashed chats to restore or permanently delete.")
                .foregroundStyle(.secondary)
        } else {
            Text("\(threadCount) chats · \(backupCount) backup files selected")
                .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
            model.revealSelectedTrashThreadsInFinder()
        } label: {
            Label("Reveal Chat", systemImage: "folder")
        }
        .disabled(model.selectedTrashThreadIDs.isEmpty || model.isDemoMode)

        Button {
            isConfirmingRestoreTrashThread = true
        } label: {
            Label("Restore Chat", systemImage: "arrow.counterclockwise")
        }
        .disabled(model.selectedTrashThreads.count != 1 || model.isLoadingBackups)

        Button(role: .destructive) {
            isConfirmingDeleteTrashThreads = true
        } label: {
            Label("Delete Chat", systemImage: "trash.slash")
        }
        .disabled(model.selectedTrashThreadIDs.isEmpty || model.isLoadingBackups)

        Button(role: .destructive) {
            isConfirmingEmptyTrash = true
        } label: {
            Label("Empty Trash", systemImage: "trash.slash")
        }
        .disabled(model.trashItemCount == 0 || model.isLoadingBackups)
    }

    private var canRestoreSelectedBackup: Bool {
        model.selectedBackups.count == 1 && model.selectedBackups.first?.kind == .chatFile
    }
}

private enum BackupManagerTab: String, CaseIterable, Identifiable {
    case backups
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backups: return "Backups"
        case .trash: return "Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .backups: return "archivebox"
        case .trash: return "trash"
        }
    }
}
