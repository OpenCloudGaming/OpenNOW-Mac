import AppKit
import SwiftUI

@MainActor
final class ControllerOrderWindowReference {
    weak var window: NSWindow?
    var acceptsInput: Bool { NSApplication.shared.isActive && window?.isKeyWindow == true }
}

struct ControllerOrderWindowReader: NSViewRepresentable {
    let reference: ControllerOrderWindowReference

    func makeNSView(context: Context) -> WindowProbe { WindowProbe(reference: reference) }
    func updateNSView(_ nsView: WindowProbe, context: Context) { nsView.reference.window = nsView.window }

    final class WindowProbe: NSView {
        let reference: ControllerOrderWindowReference

        init(reference: ControllerOrderWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference.window = window
        }
    }
}
