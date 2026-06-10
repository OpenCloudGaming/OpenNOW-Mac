import AppKit
import GameController
import QuartzCore

private struct OPNCloudmatchGamepadButton: OptionSet {
    let rawValue: UInt16

    static let up = OPNCloudmatchGamepadButton(rawValue: 1 << 0)
    static let down = OPNCloudmatchGamepadButton(rawValue: 1 << 1)
    static let a = OPNCloudmatchGamepadButton(rawValue: 1 << 2)
    static let b = OPNCloudmatchGamepadButton(rawValue: 1 << 3)
    static let y = OPNCloudmatchGamepadButton(rawValue: 1 << 4)
}

private let opnCloudmatchKeyCodeReturn: UInt16 = 36
private let opnCloudmatchKeyCodeEnter: UInt16 = 76
private let opnCloudmatchKeyCodeEscape: UInt16 = 53
private let opnCloudmatchKeyCodeDownArrow: UInt16 = 125
private let opnCloudmatchKeyCodeUpArrow: UInt16 = 126

private func opnCloudmatchGamepadButtons() -> OPNCloudmatchGamepadButton {
    guard let pad = GCController.controllers().first?.extendedGamepad else { return [] }
    var buttons: OPNCloudmatchGamepadButton = []
    let y = CGFloat(pad.leftThumbstick.yAxis.value)
    if pad.dpad.up.value > 0.5 || y > 0.55 { buttons.insert(.up) }
    if pad.dpad.down.value > 0.5 || y < -0.55 { buttons.insert(.down) }
    if pad.buttonA.value > 0.5 { buttons.insert(.a) }
    if pad.buttonB.value > 0.5 { buttons.insert(.b) }
    if pad.buttonY.value > 0.5 { buttons.insert(.y) }
    return buttons
}

@objc(OPNCloudmatchServerOption)
final class OPNCloudmatchServerOption: NSObject {
    @objc let name: String
    @objc let url: String
    @objc let latencyMs: Int
    @objc(isAutomatic) let automatic: Bool

    @objc var latencyText: String {
        if latencyMs < 0 { return "Measuring" }
        return automatic ? "Best \(latencyMs) ms" : "\(latencyMs) ms"
    }

    @objc var detailText: String {
        if automatic {
            return latencyMs >= 0 ? "Lowest measured region" : "Best available region"
        }
        return name.isEmpty ? "Cloudmatch region" : name
    }

    @objc(initWithName:url:latencyMs:automatic:)
    init(name: String, url: String, latencyMs: Int, automatic: Bool) {
        self.name = name.isEmpty ? "Cloudmatch" : name
        self.url = url.isEmpty ? "" : url
        self.latencyMs = latencyMs
        self.automatic = automatic
        super.init()
    }
}

private final class OPNCloudmatchFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class OPNCloudmatchServerRowView: NSControl {
    let option: OPNCloudmatchServerOption
    let optionIndex: Int
    private let nameLabel: NSTextField
    private let latencyLabel: NSTextField

    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            updateAppearance()
        }
    }

    init(frame frameRect: NSRect, option: OPNCloudmatchServerOption, optionIndex: Int) {
        self.option = option
        self.optionIndex = optionIndex
        nameLabel = opnLabel(option.name.isEmpty ? "Cloudmatch region" : option.name, .zero, 13.5, opnColor(OPNViewColor.textPrimary), .bold)
        latencyLabel = opnLabel(option.latencyText, .zero, 12.0, OPNCloudmatchServerRowView.latencyColor(for: option.latencyMs), .bold, .center)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 12.0
        layer?.borderWidth = 1.0
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        latencyLabel.wantsLayer = true
        latencyLabel.layer?.cornerRadius = 9.0
        addSubview(latencyLabel)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        let contentX: CGFloat = 12.0
        let latencyWidth: CGFloat = 86.0
        let labelWidth = max(80.0, width - contentX - latencyWidth - 24.0)
        nameLabel.frame = NSRect(x: contentX, y: 8.0, width: labelWidth, height: 19.0)
        latencyLabel.frame = NSRect(x: width - latencyWidth - 12.0, y: 7.0, width: latencyWidth, height: 20.0)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    private static func latencyColor(for latencyMs: Int) -> NSColor {
        if latencyMs < 0 { return opnColor(0x8E8E93) }
        if latencyMs <= 50 { return opnColor(OPNViewColor.brandGreen) }
        if latencyMs <= 85 { return opnColor(0xFFD166) }
        return opnColor(OPNViewColor.errorRed)
    }

    private func updateAppearance() {
        layer?.backgroundColor = (selected ? opnColor(0x102116, 0.50) : opnColor(0x0D1013, 0.50)).cgColor
        layer?.borderColor = (selected ? opnColor(OPNViewColor.brandGreen, 0.72) : opnColor(0xFFFFFF, 0.10)).cgColor
        nameLabel.textColor = selected ? opnColor(0xF4FFF6) : opnColor(OPNViewColor.textPrimary)
        latencyLabel.textColor = Self.latencyColor(for: option.latencyMs)
        latencyLabel.layer?.backgroundColor = (selected ? opnColor(0x06140A, 0.50) : opnColor(0x171B20, 0.50)).cgColor
    }
}

@objc(OPNCloudmatchServerPickerView)
final class OPNCloudmatchServerPickerView: NSView {
    @objc var onConfirm: ((OPNCloudmatchServerOption) -> Void)?
    @objc var onCancel: (() -> Void)?
    @objc var onRefresh: (() -> Void)?

    private let gameTitle: String
    private var options: [OPNCloudmatchServerOption] = []
    private var selectedIndex = 0
    private var selectionWasChangedByUser = false
    private var refreshing = false
    private let panel = NSView(frame: .zero)
    private let titleLabel = opnLabel("Route", .zero, 18.0, opnColor(OPNViewColor.textPrimary), .black)
    private let scrollView = NSScrollView(frame: .zero)
    private let rowsDocumentView = OPNCloudmatchFlippedView(frame: .zero)
    private var rowViews: [OPNCloudmatchServerRowView] = []
    private let refreshButton = OPNCloudmatchServerPickerView.makeButton("Refresh", background: opnColor(0x12171C, 0.50), textColor: opnColor(OPNViewColor.textPrimary), borderColor: opnColor(0xFFFFFF, 0.14))
    private let cancelButton = OPNCloudmatchServerPickerView.makeButton("Cancel", background: opnColor(0x161113, 0.50), textColor: opnColor(OPNViewColor.errorRed), borderColor: opnColor(OPNViewColor.errorRed, 0.30))
    private let confirmButton = OPNCloudmatchServerPickerView.makeButton("Launch", background: opnColor(0x102116, 0.50), textColor: opnColor(OPNViewColor.brandGreen), borderColor: opnColor(OPNViewColor.brandGreen, 0.42))
    private var controllerTimer: Timer?
    private var previousControllerButtons: OPNCloudmatchGamepadButton = []
    private var heldControllerDirections: OPNCloudmatchGamepadButton = []
    private var lastControllerRepeatTime: CFTimeInterval = 0.0

    @objc(initWithFrame:gameTitle:)
    init(frame frameRect: NSRect, gameTitle: String) {
        self.gameTitle = gameTitle.isEmpty ? "this game" : gameTitle
        super.init(frame: frameRect)
        configure()
    }

    override init(frame frameRect: NSRect) {
        self.gameTitle = "this game"
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.makeFirstResponder(self)
            startControllerPolling()
        } else {
            stopControllerPolling()
        }
    }

    override func layout() {
        super.layout()
        let hostWidth = bounds.width
        let hostHeight = bounds.height
        var panelWidth = min(460.0, max(340.0, hostWidth - 80.0))
        var panelHeight = min(420.0, max(360.0, hostHeight - 64.0))
        if hostWidth < 390.0 { panelWidth = max(300.0, hostWidth - 32.0) }
        if hostHeight < 440.0 { panelHeight = max(300.0, hostHeight - 32.0) }

        panel.frame = NSRect(x: floor((hostWidth - panelWidth) / 2.0), y: floor((hostHeight - panelHeight) / 2.0), width: panelWidth, height: panelHeight)
        let contentX: CGFloat = 18.0
        let contentWidth = panelWidth - 36.0
        titleLabel.frame = NSRect(x: contentX, y: panelHeight - 40.0, width: contentWidth, height: 22.0)

        let buttonY: CGFloat = 18.0
        let buttonHeight: CGFloat = 34.0
        let buttonGap: CGFloat = 8.0
        var refreshWidth: CGFloat = 88.0
        var confirmWidth: CGFloat = 108.0
        var cancelWidth: CGFloat = 92.0
        if refreshWidth + cancelWidth + confirmWidth + buttonGap * 2.0 > contentWidth {
            refreshWidth = floor((contentWidth - buttonGap * 2.0) / 3.0)
            cancelWidth = refreshWidth
            confirmWidth = refreshWidth
        }
        refreshButton.frame = NSRect(x: contentX, y: buttonY, width: refreshWidth, height: buttonHeight)
        confirmButton.frame = NSRect(x: contentX + contentWidth - confirmWidth, y: buttonY, width: confirmWidth, height: buttonHeight)
        cancelButton.frame = NSRect(x: confirmButton.frame.minX - buttonGap - cancelWidth, y: buttonY, width: cancelWidth, height: buttonHeight)

        let scrollY: CGFloat = 64.0
        let scrollHeight = max(110.0, panelHeight - 116.0)
        scrollView.frame = NSRect(x: contentX, y: scrollY, width: contentWidth, height: scrollHeight)
        layoutRows()
    }

    @objc(setOptions:selectedRegionUrl:refreshing:)
    func setOptions(_ options: [OPNCloudmatchServerOption], selectedRegionUrl: String, refreshing: Bool) {
        let previousSelection = selectionWasChangedByUser && selectedIndex >= 0 && selectedIndex < self.options.count ? self.options[selectedIndex] : nil
        self.options = options
        self.refreshing = refreshing
        let preferredUrl = previousSelection?.url ?? selectedRegionUrl
        selectedIndex = index(forRegionUrl: preferredUrl)
        if selectedIndex < 0 && !options.isEmpty { selectedIndex = 0 }
        renderRows()
        setRefreshing(refreshing)
    }

    @objc func setRefreshing(_ refreshing: Bool) {
        self.refreshing = refreshing
        updateActions()
    }

    @objc(setStatusMessage:isError:)
    func setStatusMessage(_ statusMessage: String, isError: Bool) {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case opnCloudmatchKeyCodeReturn, opnCloudmatchKeyCodeEnter:
            confirmClicked(nil)
            return
        case opnCloudmatchKeyCodeEscape:
            cancelClicked(nil)
            return
        case opnCloudmatchKeyCodeDownArrow:
            moveSelection(by: 1)
            return
        case opnCloudmatchKeyCodeUpArrow:
            moveSelection(by: -1)
            return
        default:
            break
        }

        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            refreshClicked(nil)
            return
        }
        super.keyDown(with: event)
    }

    private static func makeButton(_ title: String, background: NSColor, textColor: NSColor, borderColor: NSColor) -> NSButton {
        let button = opnButton(title, .zero, background, textColor)
        button.layer?.borderWidth = 1.0
        button.layer?.borderColor = borderColor.cgColor
        return button
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = opnColor(0x020304, 0.50).cgColor

        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18.0
        panel.layer?.backgroundColor = opnColor(0x090B0E, 0.50).cgColor
        panel.layer?.borderWidth = 1.0
        panel.layer?.borderColor = opnColor(0xFFFFFF, 0.12).cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.22
        panel.layer?.shadowRadius = 20.0
        panel.layer?.shadowOffset = CGSize(width: 0.0, height: 10.0)
        addSubview(panel)

        panel.addSubview(titleLabel)
        scrollView.documentView = rowsDocumentView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        panel.addSubview(scrollView)

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        panel.addSubview(refreshButton)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        panel.addSubview(cancelButton)
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked(_:))
        panel.addSubview(confirmButton)
        updateActions()
    }

    private func index(forRegionUrl regionUrl: String) -> Int {
        options.firstIndex { $0.url == regionUrl } ?? -1
    }

    private func renderRows() {
        rowsDocumentView.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        for (index, option) in options.enumerated() {
            let row = OPNCloudmatchServerRowView(frame: .zero, option: option, optionIndex: index)
            row.target = self
            row.action = #selector(rowClicked(_:))
            row.selected = index == selectedIndex
            rowsDocumentView.addSubview(row)
            rowViews.append(row)
        }
        layoutRows()
    }

    private func layoutRows() {
        let rowHeight: CGFloat = 34.0
        let rowGap: CGFloat = 6.0
        let visibleWidth = max(100.0, scrollView.contentView.bounds.width - 2.0)
        let visibleHeight = max(1.0, scrollView.contentView.bounds.height)
        let totalHeight = rowViews.isEmpty ? visibleHeight : CGFloat(rowViews.count) * rowHeight + CGFloat(max(0, rowViews.count - 1)) * rowGap
        rowsDocumentView.frame = NSRect(x: 0.0, y: 0.0, width: visibleWidth, height: max(visibleHeight, totalHeight + 2.0))
        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(x: 1.0, y: CGFloat(index) * (rowHeight + rowGap), width: visibleWidth - 2.0, height: rowHeight)
            row.needsLayout = true
        }
    }

    private func updateActions() {
        let hasSelection = selectedIndex >= 0 && selectedIndex < options.count
        confirmButton.isEnabled = hasSelection
        confirmButton.alphaValue = hasSelection ? 1.0 : 0.48
        refreshButton.isEnabled = !refreshing
        refreshButton.alphaValue = refreshing ? 0.55 : 1.0
        refreshButton.title = refreshing ? "Pinging" : "Refresh"
    }

    @objc private func rowClicked(_ sender: OPNCloudmatchServerRowView) {
        selectionWasChangedByUser = true
        selectedIndex = sender.optionIndex
        updateRowSelection()
    }

    private func updateRowSelection() {
        for row in rowViews {
            row.selected = row.optionIndex == selectedIndex
        }
        updateActions()
    }

    private func moveSelection(by delta: Int) {
        guard !options.isEmpty else { return }
        let nextIndex = max(0, min(options.count - 1, selectedIndex + delta))
        guard nextIndex != selectedIndex else { return }
        selectionWasChangedByUser = true
        selectedIndex = nextIndex
        updateRowSelection()
        scrollSelectedRowIntoView()
    }

    private func scrollSelectedRowIntoView() {
        guard selectedIndex >= 0 && selectedIndex < rowViews.count else { return }
        rowsDocumentView.scrollToVisible(rowViews[selectedIndex].frame.insetBy(dx: 0.0, dy: -10.0))
    }

    @objc private func confirmClicked(_ sender: Any?) {
        guard selectedIndex >= 0 && selectedIndex < options.count else { return }
        onConfirm?(options[selectedIndex])
    }

    @objc private func cancelClicked(_ sender: Any?) {
        onCancel?()
    }

    @objc private func refreshClicked(_ sender: Any?) {
        guard !refreshing else { return }
        onRefresh?()
    }

    private func startControllerPolling() {
        guard controllerTimer == nil else { return }
        previousControllerButtons = opnCloudmatchGamepadButtons()
        heldControllerDirections = []
        lastControllerRepeatTime = 0.0
        controllerTimer = Timer.scheduledTimer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(pollController(_:)), userInfo: nil, repeats: true)
    }

    private func stopControllerPolling() {
        controllerTimer?.invalidate()
        controllerTimer = nil
        previousControllerButtons = []
        heldControllerDirections = []
        lastControllerRepeatTime = 0.0
    }

    @objc private func pollController(_ timer: Timer) {
        let buttons = opnCloudmatchGamepadButtons()
        let pressed = OPNCloudmatchGamepadButton(rawValue: buttons.rawValue & ~previousControllerButtons.rawValue)
        let directions = OPNCloudmatchGamepadButton(rawValue: buttons.rawValue & (OPNCloudmatchGamepadButton.up.rawValue | OPNCloudmatchGamepadButton.down.rawValue))
        let now = CACurrentMediaTime()
        if directions.isEmpty {
            heldControllerDirections = []
            lastControllerRepeatTime = 0.0
        } else if directions != heldControllerDirections || now - lastControllerRepeatTime >= 0.18 {
            heldControllerDirections = directions
            lastControllerRepeatTime = now
            if directions.contains(.up) { moveSelection(by: -1) }
            if directions.contains(.down) { moveSelection(by: 1) }
        }

        if pressed.contains(.a) { confirmClicked(nil) }
        if pressed.contains(.b) { cancelClicked(nil) }
        if pressed.contains(.y) { refreshClicked(nil) }
        previousControllerButtons = buttons
    }
}
