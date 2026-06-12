import AppKit
import Combine
import SwiftUI

@MainActor
private final class OPNBackdropModel: ObservableObject {
    @Published var mode = 0
    @Published var accountName = ""
    @Published var accountStatus = ""
    @Published var remainingPlayTime = ""
    @Published var gameCountText = ""
}

@objc(OPNBackdropView)
@MainActor
final class OPNBackdropView: NSView {
    @objc var mode: Int = 0 {
        didSet { model.mode = mode }
    }

    @objc var accountName: String? {
        didSet { model.accountName = accountName ?? "" }
    }

    @objc var accountStatus: String? {
        didSet { model.accountStatus = accountStatus ?? "" }
    }

    @objc var accountAvatarImage: NSImage?

    @objc var remainingPlayTime: String? {
        didSet { model.remainingPlayTime = remainingPlayTime ?? "" }
    }

    @objc var gameCountText: String? {
        didSet { model.gameCountText = gameCountText ?? "" }
    }

    @objc var accountMenuItems: [[String: String]]?
    @objc var currentAccountIdentifier: String?
    @objc var onHomeSelected: (() -> Void)?
    @objc var onStoreSelected: (() -> Void)?
    @objc var onLibrarySelected: (() -> Void)?
    @objc var onSearchSelected: (() -> Void)?
    @objc var onSettingsSelected: (() -> Void)?
    @objc var onAccountSelected: ((String) -> Void)?
    @objc var onAddAccountSelected: (() -> Void)?
    @objc var onSignOutSelected: (() -> Void)?
    @objc var onExitSelected: (() -> Void)?

    private let model = OPNBackdropModel()
    private var hostingView: NSHostingView<OPNBackdropSwiftUIView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    @objc private func interfacePreferencesChanged(_ notification: Notification) {
        hostingView?.rootView = OPNBackdropSwiftUIView(model: model)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(interfacePreferencesChanged(_:)),
            name: NSNotification.Name("OpenNOW.InterfacePreferencesDidChange"),
            object: nil
        )

        let hosting = NSHostingView(rootView: OPNBackdropSwiftUIView(model: model))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting, positioned: .below, relativeTo: nil)
        hostingView = hosting
    }
}

private struct OPNBackdropSwiftUIView: View {
    @ObservedObject var model: OPNBackdropModel

    var body: some View {
        ZStack {
            baseGradient
            modeWash
            VStack(spacing: 0) {
                topGlow
                Spacer(minLength: 0)
                bottomGlow
            }
        }
        .ignoresSafeArea()
    }

    private var baseGradient: some View {
        LinearGradient(
            colors: [
                Color(nsColor: OPNUIHelpers.color(rgb: 0x05070A, alpha: 1.0)),
                Color(nsColor: OPNUIHelpers.color(rgb: 0x0B1115, alpha: 1.0)),
                Color(nsColor: OPNUIHelpers.color(rgb: 0x020304, alpha: 1.0))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var modeWash: some View {
        RadialGradient(
            colors: [modeColor.opacity(0.34), modeColor.opacity(0.08), .clear],
            center: .topTrailing,
            startRadius: 80,
            endRadius: 760
        )
        .blendMode(.screen)
    }

    private var topGlow: some View {
        LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 170)
    }

    private var bottomGlow: some View {
        RadialGradient(colors: [Color.black.opacity(0.32), .clear], center: .bottom, startRadius: 40, endRadius: 520)
            .frame(height: 240)
    }

    private var modeColor: Color {
        switch model.mode {
        case 2:
            return Color(nsColor: OPNUIHelpers.color(rgb: 0x34C759, alpha: 1.0))
        case 3:
            return Color(nsColor: OPNUIHelpers.color(rgb: 0x0A84FF, alpha: 1.0))
        case 4:
            return Color(nsColor: OPNUIHelpers.color(rgb: 0xBF5AF2, alpha: 1.0))
        default:
            return Color(nsColor: OPNUIHelpers.color(rgb: 0x1D9BF0, alpha: 1.0))
        }
    }
}
