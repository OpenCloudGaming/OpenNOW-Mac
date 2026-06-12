import AppKit
import Combine
import GameController
import QuartzCore
import SwiftUI

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

@MainActor
private final class OPNCloudmatchServerPickerModel: ObservableObject {
    @Published var options: [OPNCloudmatchServerOption] = []
    @Published var selectedIndex = 0
    @Published var selectionWasChangedByUser = false
    @Published var refreshing = false
    @Published var statusMessage = ""
    @Published var statusIsError = false

    let gameTitle: String

    init(gameTitle: String) {
        self.gameTitle = gameTitle.isEmpty ? "this game" : gameTitle
    }

    var selectedOption: OPNCloudmatchServerOption? {
        guard selectedIndex >= 0 && selectedIndex < options.count else { return nil }
        return options[selectedIndex]
    }

    var hasSelection: Bool {
        selectedOption != nil
    }

    func setOptions(_ nextOptions: [OPNCloudmatchServerOption], selectedRegionUrl: String, refreshing: Bool) {
        let previousSelection = selectionWasChangedByUser ? selectedOption : nil
        options = nextOptions
        self.refreshing = refreshing
        let preferredUrl = previousSelection?.url ?? selectedRegionUrl
        selectedIndex = index(forRegionUrl: preferredUrl)
        if selectedIndex < 0 && !nextOptions.isEmpty { selectedIndex = 0 }
    }

    func setStatusMessage(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    func select(index: Int) {
        guard index >= 0 && index < options.count else { return }
        selectionWasChangedByUser = true
        selectedIndex = index
    }

    func moveSelection(by delta: Int) {
        guard !options.isEmpty else { return }
        let nextIndex = max(0, min(options.count - 1, selectedIndex + delta))
        guard nextIndex != selectedIndex else { return }
        selectionWasChangedByUser = true
        selectedIndex = nextIndex
    }

    private func index(forRegionUrl regionUrl: String) -> Int {
        options.firstIndex { $0.url == regionUrl } ?? -1
    }
}

@objc(OPNCloudmatchServerPickerView)
@MainActor
final class OPNCloudmatchServerPickerView: NSView {
    @objc var onConfirm: ((OPNCloudmatchServerOption) -> Void)?
    @objc var onCancel: (() -> Void)?
    @objc var onRefresh: (() -> Void)?

    private let model: OPNCloudmatchServerPickerModel
    private var hostingView: NSHostingView<OPNCloudmatchServerPickerSwiftUIView>?
    private var controllerTimer: Timer?
    private var previousControllerButtons: OPNCloudmatchGamepadButton = []
    private var heldControllerDirections: OPNCloudmatchGamepadButton = []
    private var lastControllerRepeatTime: CFTimeInterval = 0.0

    @objc(initWithFrame:gameTitle:)
    init(frame frameRect: NSRect, gameTitle: String) {
        model = OPNCloudmatchServerPickerModel(gameTitle: gameTitle)
        super.init(frame: frameRect)
        configure()
    }

    override init(frame frameRect: NSRect) {
        model = OPNCloudmatchServerPickerModel(gameTitle: "this game")
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        model = OPNCloudmatchServerPickerModel(gameTitle: "this game")
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }

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
        hostingView?.frame = bounds
    }

    @objc(setOptions:selectedRegionUrl:refreshing:)
    func setOptions(_ options: [OPNCloudmatchServerOption], selectedRegionUrl: String, refreshing: Bool) {
        model.setOptions(options, selectedRegionUrl: selectedRegionUrl, refreshing: refreshing)
    }

    @objc func setRefreshing(_ refreshing: Bool) {
        model.refreshing = refreshing
    }

    @objc(setStatusMessage:isError:)
    func setStatusMessage(_ statusMessage: String, isError: Bool) {
        model.setStatusMessage(statusMessage, isError: isError)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case opnCloudmatchKeyCodeReturn, opnCloudmatchKeyCodeEnter:
            confirmSelection()
            return
        case opnCloudmatchKeyCodeEscape:
            onCancel?()
            return
        case opnCloudmatchKeyCodeDownArrow:
            model.moveSelection(by: 1)
            return
        case opnCloudmatchKeyCodeUpArrow:
            model.moveSelection(by: -1)
            return
        default:
            break
        }

        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            refreshOptions()
            return
        }
        super.keyDown(with: event)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let hosting = NSHostingView(rootView: OPNCloudmatchServerPickerSwiftUIView(
            model: model,
            onSelect: { [weak model] index in model?.select(index: index) },
            onRefresh: { [weak self] in self?.refreshOptions() },
            onCancel: { [weak self] in self?.onCancel?() },
            onConfirm: { [weak self] in self?.confirmSelection() }
        ))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }

    private func confirmSelection() {
        guard let selectedOption = model.selectedOption else { return }
        onConfirm?(selectedOption)
    }

    private func refreshOptions() {
        guard !model.refreshing else { return }
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
            if directions.contains(.up) { model.moveSelection(by: -1) }
            if directions.contains(.down) { model.moveSelection(by: 1) }
        }

        if pressed.contains(.a) { confirmSelection() }
        if pressed.contains(.b) { onCancel?() }
        if pressed.contains(.y) { refreshOptions() }
        previousControllerButtons = buttons
    }
}

private struct OPNCloudmatchServerPickerSwiftUIView: View {
    @ObservedObject var model: OPNCloudmatchServerPickerModel

    let onSelect: (Int) -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.50).ignoresSafeArea()
            panel
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            routeList
            status
            footer
        }
        .padding(18)
        .frame(minWidth: 300, idealWidth: 460, maxWidth: 460, minHeight: 300, idealHeight: 420, maxHeight: 420)
        .background(Color(nsColor: opnColor(0x090B0E, 0.86)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
        .padding(.horizontal, 16)
        .padding(.vertical, 32)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Route")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(nsColor: opnColor(OPNViewColor.textPrimary)))
            Text("Choose the Cloudmatch route for \(model.gameTitle).")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var routeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.options.enumerated()), id: \.offset) { index, option in
                        OPNCloudmatchServerOptionRow(option: option, selected: index == model.selectedIndex) {
                            onSelect(index)
                        }
                        .id(index)
                    }

                    if model.options.isEmpty {
                        Text(model.refreshing ? "Measuring routes..." : "No routes available.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 110)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 256)
            .onChange(of: model.selectedIndex) { _, selectedIndex in
                withAnimation(.snappy(duration: 0.16)) {
                    proxy.scrollTo(selectedIndex, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if !model.statusMessage.isEmpty {
            Text(model.statusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.statusIsError ? Color(nsColor: opnColor(OPNViewColor.errorRed)) : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.refreshing ? "Pinging" : "Refresh") { onRefresh() }
                .disabled(model.refreshing)
                .buttonStyle(OPNCloudmatchButtonStyle(
                    foreground: Color(nsColor: opnColor(OPNViewColor.textPrimary)),
                    background: Color(nsColor: opnColor(0x12171C, 0.50)),
                    border: .white.opacity(0.14)
                ))
                .frame(width: 88, height: 34)

            Spacer(minLength: 8)

            Button("Cancel") { onCancel() }
                .buttonStyle(OPNCloudmatchButtonStyle(
                    foreground: Color(nsColor: opnColor(OPNViewColor.errorRed)),
                    background: Color(nsColor: opnColor(0x161113, 0.50)),
                    border: Color(nsColor: opnColor(OPNViewColor.errorRed)).opacity(0.30)
                ))
                .frame(width: 92, height: 34)

            Button("Launch") { onConfirm() }
                .disabled(!model.hasSelection)
                .buttonStyle(OPNCloudmatchButtonStyle(
                    foreground: Color(nsColor: opnColor(OPNViewColor.brandGreen)),
                    background: Color(nsColor: opnColor(0x102116, 0.50)),
                    border: Color(nsColor: opnColor(OPNViewColor.brandGreen)).opacity(0.42)
                ))
                .frame(width: 108, height: 34)
        }
    }
}

private struct OPNCloudmatchServerOptionRow: View {
    let option: OPNCloudmatchServerOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name.isEmpty ? "Cloudmatch region" : option.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(selected ? Color(nsColor: opnColor(0xF4FFF6)) : Color(nsColor: opnColor(OPNViewColor.textPrimary)))
                        .lineLimit(1)
                    Text(option.detailText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(option.latencyText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(latencyColor)
                    .lineLimit(1)
                    .frame(width: 86, height: 20)
                    .background(selected ? Color(nsColor: opnColor(0x06140A, 0.50)) : Color(nsColor: opnColor(0x171B20, 0.50)), in: Capsule())
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? Color(nsColor: opnColor(0x102116, 0.50)) : Color(nsColor: opnColor(0x0D1013, 0.50)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Color(nsColor: opnColor(OPNViewColor.brandGreen)).opacity(0.72) : .white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var latencyColor: Color {
        if option.latencyMs < 0 { return Color(nsColor: opnColor(0x8E8E93)) }
        if option.latencyMs <= 50 { return Color(nsColor: opnColor(OPNViewColor.brandGreen)) }
        if option.latencyMs <= 85 { return Color(nsColor: opnColor(0xFFD166)) }
        return Color(nsColor: opnColor(OPNViewColor.errorRed))
    }
}

private struct OPNCloudmatchButtonStyle: ButtonStyle {
    let foreground: Color
    let background: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1.0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.86 : 1.0)
    }
}
