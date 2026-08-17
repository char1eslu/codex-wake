import SwiftUI
import AppKit
import CodexKeeperCore

struct ThreadDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var activePane: WakeFocusPane
    @State private var isMoveSheetPresented = false
    @State private var detailScrollViewBox = WeakScrollViewBox()
    @State private var detailTopAnchorBox = WeakViewBox()

    var body: some View {
        Group {
            if let thread = model.selectedThread {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header(thread)
                                .id(DetailScrollTarget.top(for: thread.id))
                                .background(alignment: .topLeading) {
                                    DetailTopAnchorAccessor(viewBox: detailTopAnchorBox)
                                        .frame(width: 0, height: 0)
                                }
                            metadata(thread)
                            actions(thread)
                            operationReport
                            preview
                            Color.clear
                                .frame(height: 1)
                                .id(DetailScrollTarget.bottom(for: thread.id))
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            DetailScrollViewAccessor(scrollViewBox: detailScrollViewBox)
                                .frame(width: 0, height: 0)
                        }
                    }
                    .id(model.selectedThreadID)
                    .onTapGesture {
                        setActivePane(.detail)
                    }
                    .onChange(of: model.selectedThreadID) { _, _ in
                        detailScrollViewBox = WeakScrollViewBox()
                        detailTopAnchorBox = WeakViewBox()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .codexWakeScrollDetail)) { notification in
                        guard let action = notification.object as? WakeDetailScrollAction else { return }
                        handleDetailScroll(action, proxy: proxy)
                    }
                }
            } else {
                ContentUnavailableView("Select a chat", systemImage: "text.bubble")
                    .onTapGesture {
                        setActivePane(.detail)
                    }
            }
        }
        .sheet(isPresented: $isMoveSheetPresented) {
            MoveThreadSheet(isPresented: $isMoveSheetPresented)
                .environmentObject(model)
        }
    }

    private func header(_ thread: CodexThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(thread.shortTitle)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(thread.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                CopyFeedbackButton(text: thread.id, help: "Copy chat ID")
            }
        }
    }

    private func metadata(_ thread: CodexThread) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            row("Project", thread.cwd)
            row("Rollout", thread.rolloutPath)
            row("Created", WakeDates.display(thread.createdAt))
            row("Updated", WakeDates.display(thread.updatedAt))
            row("Session index", WakeDates.display(thread.sessionIndexUpdatedAt))
            row("Session meta", WakeDates.display(thread.sessionMetaTimestamp))
            row("Thread source", thread.threadSource.isEmpty ? "NULL" : thread.threadSource)
            if thread.childThreadCount > 0 {
                row("Subagents", String(thread.childThreadCount))
            }
            row("Archived", thread.archived ? "yes" : "no")
            row("File exists", thread.fileExists ? "yes" : "no")
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(3)
        }
    }

    private func actions(_ thread: CodexThread) -> some View {
        HStack(spacing: 8) {
            repairButton(thread)
            moveButton(thread)
            revealButton(thread)
            trashButton(thread)
            copyPathButton(thread)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .liquidGlassContainer(spacing: 8)
    }

    private func repairButton(_ thread: CodexThread) -> some View {
        Button {
            model.selectThread(thread)
            Task { await model.wakeSelectedThread() }
        } label: {
            actionLabel("Repair Index", systemImage: "wrench.and.screwdriver")
        }
        .liquidGlassProminentButtonStyle()
        .disabled(model.isLoading || !thread.needsRepair)
        .help(model.isDemoMode ? "Show a demo repair report without changing local files" : "Back up metadata and add the missing session_index.jsonl entry")
    }

    private func moveButton(_ thread: CodexThread) -> some View {
        Button {
            model.selectThread(thread)
            isMoveSheetPresented = true
        } label: {
            actionLabel("Move", systemImage: "folder.badge.plus")
        }
        .liquidGlassButtonStyle()
        .disabled(model.isLoading || model.moveTargetProjects.isEmpty || thread.archived || !thread.fileExists)
        .help("Move this chat to another known project")
    }

    private func revealButton(_ thread: CodexThread) -> some View {
        Button {
            model.selectThread(thread)
            model.revealSelectedInFinder()
        } label: {
            actionLabel("Reveal", systemImage: "folder")
        }
        .liquidGlassButtonStyle()
        .disabled(model.isDemoMode)
    }

    private func trashButton(_ thread: CodexThread) -> some View {
        Button(role: .destructive) {
            model.selectThread(thread)
            Task { await model.moveSelectedThreadsToTrash() }
        } label: {
            actionLabel("Trash", systemImage: "trash")
        }
        .liquidGlassButtonStyle()
        .disabled(model.isLoading)
    }

    private func copyPathButton(_ thread: CodexThread) -> some View {
        CopyFeedbackButton(
            text: thread.rolloutPath,
            help: "Copy chat path",
            label: "Copy Path",
            usesPlainButtonStyle: false,
            normalForeground: .primary
        )
        .liquidGlassButtonStyle()
        .disabled(model.isDemoMode)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var operationReport: some View {
        if let report = model.selectedOperationReport {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(report.title)
                        .font(.headline)
                    Spacer()
                    Text(report.timestamp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(report.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if !report.changedFiles.isEmpty {
                    Text("Changed files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(report.changedFiles, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }

                if !report.backups.isEmpty {
                    Text("Backups")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(report.backups, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }

                if !report.failures.isEmpty {
                    Text("Failures")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    ForEach(report.failures, id: \.self) { failure in
                        Text(failure).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(12)
            .liquidGlassSurface(
                in: RoundedRectangle.compactLiquidGlass,
                tint: report.failures.isEmpty ? .green.opacity(0.14) : .orange.opacity(0.16)
            )
        }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.headline)
            if let rawError = model.preview?.rawError {
                Text(rawError)
                    .foregroundStyle(.red)
            } else if let messages = model.preview?.messages, !messages.isEmpty {
                PreviewMessagesView(messages: messages)
            } else if model.isPreviewLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading preview...")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassSurface(in: RoundedRectangle.compactLiquidGlass, interactive: true, fallbackMaterial: .thinMaterial)
            } else {
                Text("No message preview parsed yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setActivePane(_ pane: WakeFocusPane) {
        activePane = pane
    }

    @discardableResult
    private func scrollDetail(by direction: CGFloat, pageScale: CGFloat = 0.62) -> DetailScrollBoundary {
        guard let scrollView = detailScrollViewBox.scrollView,
              let documentView = scrollView.documentView
        else { return .unknown }

        let visibleHeight = scrollView.contentView.bounds.height
        let delta = max(96, min(visibleHeight * 0.92, visibleHeight * pageScale))
        let signedDelta = documentView.isFlipped ? direction * delta : -direction * delta
        let previousOrigin = scrollView.contentView.bounds.origin
        var origin = previousOrigin
        origin.y += signedDelta
        origin = constrainedScrollOrigin(origin, in: scrollView)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if abs(origin.y - previousOrigin.y) < 1 {
            if direction < 0 {
                return .top
            }
            if direction > 0 {
                return .bottom
            }
        }

        let topOrigin = detailBoundaryOrigin(.top, in: scrollView, documentView: documentView)
        let bottomOrigin = detailBoundaryOrigin(.bottom, in: scrollView, documentView: documentView)
        if abs(origin.y - topOrigin.y) < 1 {
            return .top
        }
        if abs(origin.y - bottomOrigin.y) < 1 {
            return .bottom
        }
        return .middle
    }

    private func handleDetailScroll(_ action: WakeDetailScrollAction, proxy: ScrollViewProxy) {
        guard let threadID = model.selectedThreadID else { return }

        switch action {
        case .step(let direction):
            let boundary = scrollDetail(by: CGFloat(direction), pageScale: 0.46)
            alignDetailIfNeeded(boundary, direction: direction, threadID: threadID, proxy: proxy)
        case .page(let direction):
            let boundary = scrollDetail(by: CGFloat(direction), pageScale: 0.86)
            alignDetailIfNeeded(boundary, direction: direction, threadID: threadID, proxy: proxy)
        case .top:
            scrollDetailToTop(proxy: proxy, threadID: threadID)
        case .bottom:
            scrollDetailToBottom(proxy: proxy, threadID: threadID)
        }
    }

    private func alignDetailIfNeeded(_ boundary: DetailScrollBoundary, direction: Double, threadID: String, proxy: ScrollViewProxy) {
        switch (boundary, direction) {
        case (.top, ..<0):
            scrollDetailToTop(proxy: proxy, threadID: threadID)
        case (.bottom, 0...):
            scrollDetailToBottom(proxy: proxy, threadID: threadID)
        default:
            break
        }
    }

    private func scrollDetailToTop(proxy: ScrollViewProxy, threadID: String?) {
        guard let threadID else { return }

        _ = setDetailScrollBoundary(.top)
        scrollDetailToTopNow(proxy: proxy, threadID: threadID)
    }

    private func scrollDetailToTopNow(proxy: ScrollViewProxy, threadID: String) {
        if setDetailScrollToTopAnchor() {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(DetailScrollTarget.top(for: threadID), anchor: .top)
        }
    }

    private func scrollDetailToBottom(proxy: ScrollViewProxy, threadID: String) {
        setDetailScrollBoundary(.bottom)
        proxy.scrollTo(DetailScrollTarget.bottom(for: threadID), anchor: .bottom)
    }

    @discardableResult
    private func setDetailScrollBoundary(_ boundary: DetailScrollBoundary) -> Bool {
        guard let scrollView = detailScrollViewBox.scrollView,
              let documentView = scrollView.documentView
        else { return false }

        switch boundary {
        case .middle, .unknown:
            return false
        case .top, .bottom:
            let origin = detailBoundaryOrigin(boundary, in: scrollView, documentView: documentView)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return true
        }
    }

    private func detailBoundaryOrigin(_ boundary: DetailScrollBoundary, in scrollView: NSScrollView, documentView: NSView) -> CGPoint {
        let visibleHeight = scrollView.contentView.bounds.height
        let span = max(
            documentView.bounds.height + visibleHeight + abs(documentView.bounds.minY) + abs(documentView.frame.minY) + 10_000,
            10_000
        )
        let movesTowardNegativeY: Bool
        switch boundary {
        case .top:
            movesTowardNegativeY = documentView.isFlipped
        case .bottom:
            movesTowardNegativeY = !documentView.isFlipped
        case .middle, .unknown:
            return scrollView.contentView.bounds.origin
        }

        var origin = scrollView.contentView.bounds.origin
        origin.y += movesTowardNegativeY ? -span : span
        return constrainedScrollOrigin(origin, in: scrollView)
    }

    private func setDetailScrollToTopAnchor() -> Bool {
        guard let scrollView = detailScrollViewBox.scrollView,
              let documentView = scrollView.documentView,
              let anchorView = detailTopAnchorBox.view
        else { return false }

        let anchorFrame = anchorView.convert(anchorView.bounds, to: documentView)
        let visibleHeight = scrollView.contentView.bounds.height
        var origin = scrollView.contentView.bounds.origin
        origin.y = documentView.isFlipped ? anchorFrame.minY : anchorFrame.maxY - visibleHeight
        origin = constrainedScrollOrigin(origin, in: scrollView)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    private func constrainedScrollOrigin(_ origin: CGPoint, in scrollView: NSScrollView) -> CGPoint {
        var bounds = scrollView.contentView.bounds
        bounds.origin = origin
        return scrollView.contentView.constrainBoundsRect(bounds).origin
    }
}

private enum DetailScrollTarget {
    static func top(for threadID: String) -> String {
        "detail-top-\(threadID)"
    }

    static func bottom(for threadID: String) -> String {
        "detail-bottom-\(threadID)"
    }
}

private enum DetailScrollBoundary {
    case top
    case middle
    case bottom
    case unknown
}

private final class WeakScrollViewBox {
    weak var scrollView: NSScrollView?
}

private final class WeakViewBox {
    weak var view: NSView?
}

private struct DetailTopAnchorAccessor: NSViewRepresentable {
    let viewBox: WeakViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        viewBox.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        viewBox.view = nsView
    }
}

private struct DetailScrollViewAccessor: NSViewRepresentable {
    let scrollViewBox: WeakScrollViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateScrollView(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateScrollView(from: nsView)
    }

    private func updateScrollView(from view: NSView) {
        assignScrollView(from: view)
        DispatchQueue.main.async {
            assignScrollView(from: view)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            assignScrollView(from: view)
        }
    }

    private func assignScrollView(from view: NSView) {
        if let scrollView = findScrollView(from: view) {
            scrollViewBox.scrollView = scrollView
        }
    }

    private func findScrollView(from view: NSView) -> NSScrollView? {
        if let enclosing = view.enclosingScrollView {
            return enclosing
        }

        var current = view.superview
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }
}

struct MoveThreadSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var selectedProjectID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.selectedThreadCount > 1 ? "Move Chats" : "Move Chat")
                    .font(.title3.weight(.semibold))
                Text(selectionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            List(model.moveTargetProjects, selection: $selectedProjectID) { project in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(project.totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(project.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(project.id as String?)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Move") {
                    guard let selectedProject else { return }
                    isPresented = false
                    Task { await model.moveSelectedThreads(to: selectedProject) }
                }
                .liquidGlassProminentButtonStyle()
                .disabled(selectedProject == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
        .liquidGlassBackground
        .onAppear {
            selectedProjectID = model.moveTargetProjects.first?.id
        }
    }

    private var selectionSummary: String {
        if model.selectedThreadCount > 1 {
            return "\(model.selectedThreadCount) selected chats"
        }
        return model.selectedThread?.shortTitle ?? "No chat selected"
    }

    private var selectedProject: ProjectSummary? {
        guard let selectedProjectID else { return nil }
        return model.moveTargetProjects.first { $0.id == selectedProjectID }
    }
}
