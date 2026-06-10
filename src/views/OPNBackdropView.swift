import AppKit

@objc(OPNBackdropView)
final class OPNBackdropView: NSView {
    @objc var mode: Int = 0 {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    @objc var accountName: String? {
        didSet { needsDisplay = true }
    }

    @objc var accountStatus: String? {
        didSet { needsDisplay = true }
    }

    @objc var accountAvatarImage: NSImage? {
        didSet { needsDisplay = true }
    }

    @objc var remainingPlayTime: String? {
        didSet { needsDisplay = true }
    }

    @objc var gameCountText: String? {
        didSet { needsDisplay = true }
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(interfacePreferencesChanged(_:)),
            name: NSNotification.Name("OpenNOW.InterfacePreferencesDidChange"),
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(interfacePreferencesChanged(_:)),
            name: NSNotification.Name("OpenNOW.InterfacePreferencesDidChange"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    @objc private func interfacePreferencesChanged(_ notification: Notification) {
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}
