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

@MainActor
private final class OPNDesktopChromeModel: ObservableObject {
    @Published var visible = false
    @Published var accountName = "Account"
    @Published var accountStatus = ""
    @Published var remainingPlayTime = ""
    @Published var accountMenuItems: [[String: String]] = []
    @Published var currentAccountIdentifier = ""
    @Published var settingsSelected = false
}

@objc(OPNDesktopChromeView)
@MainActor
final class OPNDesktopChromeView: NSView {
    @objc var visible: Bool = false { didSet { model.visible = visible } }
    @objc var accountName: String = "Account" { didSet { model.accountName = accountName.isEmpty ? "Account" : accountName } }
    @objc var accountStatus: String = "" { didSet { model.accountStatus = accountStatus } }
    @objc var remainingPlayTime: String = "" { didSet { model.remainingPlayTime = remainingPlayTime } }
    @objc var accountMenuItems: [[String: String]] = [] { didSet { model.accountMenuItems = accountMenuItems } }
    @objc var currentAccountIdentifier: String = "" { didSet { model.currentAccountIdentifier = currentAccountIdentifier } }
    @objc var settingsSelected: Bool = false { didSet { model.settingsSelected = settingsSelected } }

    @objc var onAccountSelected: ((String) -> Void)?
    @objc var onAddAccountSelected: (() -> Void)?
    @objc var onManageAccountSelected: (() -> Void)?
    @objc var onSettingsSelected: (() -> Void)?

    private let model = OPNDesktopChromeModel()
    private var hostingView: NSHostingView<OPNDesktopChromeSwiftUIView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let hosting = NSHostingView(rootView: OPNDesktopChromeSwiftUIView(
            model: model,
            selectAccount: { [weak self] identifier in self?.onAccountSelected?(identifier) },
            addAccount: { [weak self] in self?.onAddAccountSelected?() },
            manageAccount: { [weak self] in self?.onManageAccountSelected?() },
            openSettings: { [weak self] in self?.onSettingsSelected?() }
        ))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNDesktopChromeSwiftUIView: View {
    @ObservedObject var model: OPNDesktopChromeModel

    let selectAccount: (String) -> Void
    let addAccount: () -> Void
    let manageAccount: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("OpenNOW")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0xF5F5F7, alpha: 1.0)))
                .shadow(color: .black.opacity(0.95), radius: 3)

            Spacer(minLength: 24)

            if !model.remainingPlayTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Playtime: \(model.remainingPlayTime)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .frame(width: 172, height: 44)
                    .background(.black.opacity(0.50), in: Capsule())
            }

            Button(action: openSettings) {
                Text("Settings")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(model.settingsSelected ? .black.opacity(0.96) : .white.opacity(0.96))
                    .frame(width: 124, height: 44)
                    .background(model.settingsSelected ? Color(nsColor: OPNUIHelpers.color(rgb: 0x34C759, alpha: 0.94)) : .black.opacity(0.50), in: Capsule())
            }
            .buttonStyle(.plain)

            accountMenu
        }
        .padding(.leading, 48)
        .padding(.trailing, 58)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .opacity(model.visible ? 1 : 0)
        .allowsHitTesting(model.visible)
    }

    private var accountMenu: some View {
        Menu {
            ForEach(model.accountMenuItems, id: \.self) { item in
                let identifier = item["identifier"] ?? ""
                let label = item["label"] ?? "Account"
                Button(identifier == model.currentAccountIdentifier ? "✓ \(label)" : label) {
                    if !identifier.isEmpty { selectAccount(identifier) }
                }
            }

            if !model.accountMenuItems.isEmpty { Divider() }

            Button("Manage Account") { manageAccount() }
            Button("Add Account...") { addAccount() }
        } label: {
            VStack(spacing: 4) {
                Text(model.accountName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !model.accountStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(model.accountStatus) Account")
                        .font(.system(size: 9.5, weight: .black))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.96))
            .frame(width: 180, height: 44)
            .background(.black.opacity(0.50), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

@objc(OPNActiveSessionPromptView)
@MainActor
final class OPNActiveSessionPromptView: NSView {
    @objc var onContinue: (() -> Void)?
    @objc var onDelete: (() -> Void)?

    private var hostingView: NSHostingView<OPNActiveSessionPromptSwiftUIView>?

    @objc(initWithFrame:sessionTitle:selectedGameTitle:)
    init(frame frameRect: NSRect, sessionTitle: String, selectedGameTitle: String) {
        super.init(frame: frameRect)
        configure(sessionTitle: sessionTitle, selectedGameTitle: selectedGameTitle)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(sessionTitle: "", selectedGameTitle: "")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure(sessionTitle: "", selectedGameTitle: "")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    private func configure(sessionTitle: String, selectedGameTitle: String) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let hosting = NSHostingView(rootView: OPNActiveSessionPromptSwiftUIView(
            sessionTitle: sessionTitle,
            selectedGameTitle: selectedGameTitle,
            onContinue: { [weak self] in self?.onContinue?() },
            onDelete: { [weak self] in self?.onDelete?() }
        ))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNActiveSessionPromptSwiftUIView: View {
    let sessionTitle: String
    let selectedGameTitle: String
    let onContinue: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: OPNUIHelpers.color(rgb: 0x020304, alpha: 0.82)).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: OPNUIHelpers.color(rgb: 0x34C759, alpha: 0.88)))
                    .frame(width: 80, height: 3)
                    .padding(.top, 28)

                Text("ACTIVE SESSION")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0x34C759, alpha: 1)))
                    .padding(.top, 22)

                Text("Resume or Replace")
                    .font(.system(size: 31, weight: .black))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0xF5F5F7, alpha: 1)))
                    .padding(.top, 6)

                Text(bodyText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0xB7B8BE, alpha: 1)))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(height: 1)
                    .padding(.top, 18)

                HStack(spacing: 14) {
                    Button("A  Continue Session") { onContinue() }
                        .buttonStyle(OPNActivePromptButtonStyle(foreground: Color(nsColor: OPNUIHelpers.color(rgb: 0x34C759, alpha: 1)), border: Color(nsColor: OPNUIHelpers.color(rgb: 0x34C759, alpha: 0.52))))
                    Button("Y  Delete Session") { onDelete() }
                        .buttonStyle(OPNActivePromptButtonStyle(foreground: Color(nsColor: OPNUIHelpers.color(rgb: 0xFF453A, alpha: 1)), border: Color(nsColor: OPNUIHelpers.color(rgb: 0xFF453A, alpha: 0.46))))
                }
                .frame(height: 48)
                .padding(.top, 22)

                Text("Choose how to handle the existing cloud session before launching.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0x787A82, alpha: 1)))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
            }
            .padding(.horizontal, 34)
            .frame(minWidth: 420, idealWidth: 640, maxWidth: 640, minHeight: 330, idealHeight: 330, maxHeight: 330, alignment: .topLeading)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x0A0C0F, alpha: 0.98)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.58), radius: 46, y: 20)
            .padding(.horizontal, 48)
        }
    }

    private var bodyText: String {
        let active = sessionTitle.isEmpty ? "the active cloud session" : sessionTitle
        let selected = selectedGameTitle.isEmpty ? "the selected game" : selectedGameTitle
        return "\(active) is already running. Continue that stream, or delete it and launch \(selected)."
    }
}

private struct OPNActivePromptButtonStyle: ButtonStyle {
    let foreground: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x11161A, alpha: configuration.isPressed ? 0.76 : 0.98)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(border, lineWidth: 1))
    }
}

@MainActor
private final class OPNOwnershipSyncProgressModel: ObservableObject {
    @Published var title = "Syncing Store Library"
    @Published var message = "Syncing your store library..."
    @Published var footer = "Waiting for GeForce NOW library updates."
}

@objc(OPNOwnershipSyncProgressView)
@MainActor
final class OPNOwnershipSyncProgressView: NSView {
    private let model = OPNOwnershipSyncProgressModel()
    private var hostingView: NSHostingView<OPNOwnershipSyncProgressSwiftUIView>?

    @objc var titleText: String = "Syncing Store Library" { didSet { model.title = titleText.isEmpty ? "Syncing Store Library" : titleText } }
    @objc var messageText: String = "Syncing your store library..." { didSet { model.message = messageText.isEmpty ? "Syncing your store library..." : messageText } }
    @objc var footerText: String = "Waiting for GeForce NOW library updates." { didSet { model.footer = footerText.isEmpty ? "Waiting for GeForce NOW library updates." : footerText } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let hosting = NSHostingView(rootView: OPNOwnershipSyncProgressSwiftUIView(model: model))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNOwnershipSyncProgressSwiftUIView: View {
    @ObservedObject var model: OPNOwnershipSyncProgressModel

    var body: some View {
        ZStack {
            Color(nsColor: OPNUIHelpers.color(rgb: 0x020304, alpha: 0.64)).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .padding(.top, 8)

                Text(model.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0xF5F5F7, alpha: 1)))
                    .lineLimit(1)

                Text(model.message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0xA8ADB7, alpha: 1)))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 34)

                Text(model.footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0x8E969F, alpha: 1)))
                    .lineLimit(1)
            }
            .padding(.horizontal, 36)
            .frame(width: 430, height: 210)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x0A0C0F, alpha: 0.98)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.34), radius: 28, y: 16)
        }
    }
}
