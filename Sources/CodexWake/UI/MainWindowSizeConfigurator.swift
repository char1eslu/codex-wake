import SwiftUI
import AppKit

enum MainWindowMetrics {
    static let defaultSize = CGSize(width: 1200, height: 890)
    static let minimumSize = CGSize(width: 1120, height: 720)
}

struct MainWindowSizeConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWhenAttached(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenAttached(nsView, context: context)
    }

    private func configureWhenAttached(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.configure(window)
        }
    }

    final class Coordinator {
        private var didConfigure = false

        func configure(_ window: NSWindow) {
            guard !didConfigure else { return }
            didConfigure = true

            window.minSize = MainWindowMetrics.minimumSize
            window.setFrame(centeredFrame(for: window), display: true)
        }

        private func centeredFrame(for window: NSWindow) -> NSRect {
            let size = MainWindowMetrics.defaultSize
            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
            return NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}
