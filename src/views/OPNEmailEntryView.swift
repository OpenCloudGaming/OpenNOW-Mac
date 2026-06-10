import AppKit

@objc(OPNEmailEntryView)
final class OPNEmailEntryView: NSView {
    @objc var onSignInWithBrowser: (() -> Void)?
    @objc var stayLoggedInToggle = NSButton(frame: .zero)

    private let contentView = NSView(frame: NSRect(x: 0.0, y: 0.0, width: 480.0, height: 500.0))
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var providerIds = [String]()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        setProviderItems(ids: ["DEFAULT"], labels: ["NVIDIA"], selectedId: "DEFAULT")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
        setProviderItems(ids: ["DEFAULT"], labels: ["NVIDIA"], selectedId: "DEFAULT")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = NSRect(
            x: floor((bounds.width - 480.0) / 2.0),
            y: floor((bounds.height - 500.0) / 2.0),
            width: 480.0,
            height: 500.0
        )
    }

    @objc(setProviderItemsWithIds:labels:selectedId:)
    func setProviderItems(ids: [String], labels: [String], selectedId: String) {
        providerIds = []
        providerPopup.removeAllItems()

        for index in ids.indices {
            let id = ids[index]
            guard !id.isEmpty else { continue }
            let label = index < labels.count && !labels[index].isEmpty ? labels[index] : "NVIDIA"
            providerIds.append(id)
            providerPopup.addItem(withTitle: label)
        }

        if providerIds.isEmpty {
            providerIds = ["DEFAULT"]
            providerPopup.addItem(withTitle: "NVIDIA")
        }

        if let selectedIndex = providerIds.firstIndex(of: selectedId), selectedIndex >= 0 {
            providerPopup.selectItem(at: selectedIndex)
        } else {
            providerPopup.selectItem(at: 0)
        }
    }

    @objc func selectedProviderIdentifier() -> String {
        let index = providerPopup.indexOfSelectedItem
        guard index >= 0 && index < providerIds.count else { return "DEFAULT" }
        let id = providerIds[index]
        return id.isEmpty ? "DEFAULT" : id
    }

    private func buildUI() {
        autoresizesSubviews = true
        addSubview(contentView)

        let brand = NSView(frame: NSRect(x: 156.0, y: 12.0, width: 168.0, height: 42.0))
        brand.addSubview(opnLabel("OpenNOW", NSRect(x: 0.0, y: 9.0, width: 168.0, height: 24.0), 20.0, opnColor(OPNViewColor.textPrimary), .semibold, .center))
        contentView.addSubview(brand)

        let card = NSView(frame: NSRect(x: 40.0, y: 72.0, width: 400.0, height: 372.0))
        card.wantsLayer = true
        card.layer?.backgroundColor = opnColor(0x1D1E22, 0.86).cgColor
        card.layer?.cornerRadius = 22.0
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = opnColor(0xFFFFFF, 0.10).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.26
        card.layer?.shadowRadius = 24.0
        card.layer?.shadowOffset = CGSize(width: 0.0, height: 14.0)
        contentView.addSubview(card)

        let description = opnLabel("Access your cloud gaming library with your NVIDIA account.", NSRect(x: 56.0, y: 48.0, width: 288.0, height: 38.0), 13.0, opnColor(0x787A82), .regular, .center)
        description.maximumNumberOfLines = 2
        card.addSubview(description)
        card.addSubview(opnLabel("Sign-in provider", NSRect(x: 56.0, y: 116.0, width: 288.0, height: 18.0), 12.0, opnColor(0x787A82), .medium))

        providerPopup.frame = NSRect(x: 56.0, y: 138.0, width: 288.0, height: 38.0)
        providerPopup.isBordered = false
        providerPopup.font = NSFont.systemFont(ofSize: 14.0, weight: .medium)
        providerPopup.contentTintColor = opnColor(OPNViewColor.textPrimary)
        providerPopup.wantsLayer = true
        providerPopup.layer?.backgroundColor = opnColor(0x090F0C, 0.80).cgColor
        providerPopup.layer?.cornerRadius = 11.0
        providerPopup.layer?.borderWidth = 1.0
        providerPopup.layer?.borderColor = opnColor(0xFFFFFF, 0.10).cgColor
        card.addSubview(providerPopup)

        stayLoggedInToggle.frame = NSRect(x: 54.0, y: 210.0, width: 180.0, height: 24.0)
        stayLoggedInToggle.setButtonType(.switch)
        stayLoggedInToggle.title = "Keep me signed in"
        stayLoggedInToggle.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        stayLoggedInToggle.contentTintColor = opnColor(OPNViewColor.brandGreen)
        stayLoggedInToggle.state = loadStayLoggedIn() ? .on : .off
        card.addSubview(stayLoggedInToggle)

        let browserButton = opnButton("Continue with Browser", NSRect(x: 56.0, y: 266.0, width: 288.0, height: 48.0), opnColor(OPNViewColor.brandGreen), opnColor(OPNViewColor.accentOn))
        browserButton.font = NSFont.systemFont(ofSize: 14.0, weight: .semibold)
        browserButton.target = self
        browserButton.action = #selector(signInWithBrowserClicked)
        card.addSubview(browserButton)

        contentView.addSubview(opnLabel("Open-source cloud gaming client for macOS", NSRect(x: 0.0, y: 468.0, width: 480.0, height: 20.0), 12.0, opnColor(0x787A82), .regular, .center))
    }

    private func loadStayLoggedIn() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "OPN_StayLoggedIn") != nil { return defaults.bool(forKey: "OPN_StayLoggedIn") }
        if defaults.object(forKey: "GFN_StayLoggedIn") != nil { return defaults.bool(forKey: "GFN_StayLoggedIn") }
        return true
    }

    private func saveStayLoggedIn(_ value: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: "OPN_StayLoggedIn")
        defaults.set(value, forKey: "GFN_StayLoggedIn")
        defaults.synchronize()
    }

    @objc private func signInWithBrowserClicked() {
        saveStayLoggedIn(stayLoggedInToggle.state == .on)
        onSignInWithBrowser?()
    }
}
