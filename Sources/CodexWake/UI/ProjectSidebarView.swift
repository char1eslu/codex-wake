import SwiftUI
import CodexKeeperCore

struct ProjectSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var activePane: WakeFocusPane
    @State private var isBackupManagerPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Codex Keeper")
                    .font(.headline)
                Spacer()
                Button {
                    isBackupManagerPresented = true
                } label: {
                    Image(systemName: "archivebox")
                }
                .liquidGlassButtonStyle()
                .help("Manage backups")

                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .liquidGlassButtonStyle()
                .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            HStack(spacing: 8) {
                ForEach(SessionBackend.allCases) { backend in
                    Button {
                        model.backend = backend
                    } label: {
                        Label(backend.label, systemImage: backend.systemImage)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .liquidGlassButtonStyle()
                    .opacity(model.backend == backend ? 1 : 0.55)
                    .background(
                        model.backend == backend ? Color.accentColor.opacity(0.35) : Color.clear,
                        in: RoundedRectangle.compactLiquidGlass
                    )
                    .help("Show \(backend.label) sessions")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .liquidGlassContainer(spacing: 8)

            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(model.projects) { project in
                        ProjectRow(project: project, isSelected: project.id == model.selectedProjectID)
                            .id(project.id)
                            .contentShape(RoundedRectangle.compactLiquidGlass)
                            .onTapGesture {
                                model.selectedProjectID = project.id
                                setActivePane(.projects)
                            }
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onTapGesture {
                    setActivePane(.projects)
                }
                .onChange(of: model.selectedProjectID, initial: true) { _, selectedProjectID in
                    scrollToSelectedProject(selectedProjectID, proxy: proxy)
                }
            }
        }
        .background(.thinMaterial)
        .sheet(isPresented: $isBackupManagerPresented) {
            BackupManagerView()
                .environmentObject(model)
        }
    }

    private func setActivePane(_ pane: WakeFocusPane) {
        activePane = pane
    }

    private func scrollToSelectedProject(_ projectID: String, proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(projectID, anchor: .center)
            }
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: project.systemImage)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16)
                Text(project.name)
                    .lineLimit(1)
                Spacer()
                Text("\(project.totalCount)")
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                    .font(.caption)
            }
            HStack(spacing: 8) {
                Label("\(project.availableCount)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .green)
                if project.repairCount > 0 {
                    Label("\(project.repairCount)", systemImage: "wrench.and.screwdriver")
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .orange)
                }
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)

            if !project.path.isEmpty {
                Text(project.path)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle.compactLiquidGlass)
    }
}
