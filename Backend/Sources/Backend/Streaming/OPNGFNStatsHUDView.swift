import AppKit

@MainActor
final class OPNGFNStatsHUDView: NSView {
    private let titleLabel = OPNGFNStatsHUDView.makeLabel(size: 11, weight: .bold, color: OPNGFNStatsHUDView.green)
    private let statusLabel = OPNGFNStatsHUDView.makeLabel(size: 10, weight: .semibold, color: NSColor(calibratedWhite: 0.72, alpha: 1))
    private let rows: [OPNGFNStatsHUDRow]
    private let separator = NSView()

    override init(frame frameRect: NSRect) {
        rows = [
            OPNGFNStatsHUDRow(label: "RESOLUTION"),
            OPNGFNStatsHUDRow(label: "FPS"),
            OPNGFNStatsHUDRow(label: "RENDER FPS"),
            OPNGFNStatsHUDRow(label: "BITRATE"),
            OPNGFNStatsHUDRow(label: "PING"),
            OPNGFNStatsHUDRow(label: "JITTER"),
            OPNGFNStatsHUDRow(label: "PACKET LOSS"),
            OPNGFNStatsHUDRow(label: "FRAMES DROPPED"),
            OPNGFNStatsHUDRow(label: "CODEC"),
            OPNGFNStatsHUDRow(label: "ENHANCEMENT")
        ]
        super.init(frame: frameRect)
        initialize()
    }

    required init?(coder: NSCoder) {
        rows = []
        super.init(coder: coder)
        initialize()
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 16, y: bounds.height - 30, width: 190, height: 16)
        statusLabel.frame = NSRect(x: bounds.width - 112, y: bounds.height - 30, width: 96, height: 16)
        separator.frame = NSRect(x: 16, y: bounds.height - 41, width: bounds.width - 32, height: 1)
        let rowHeight: CGFloat = 18
        let firstY = bounds.height - 65
        for (index, row) in rows.enumerated() {
            let y = firstY - CGFloat(index) * rowHeight
            row.title.frame = NSRect(x: 16, y: y, width: 132, height: 15)
            row.value.frame = NSRect(x: 154, y: y, width: bounds.width - 170, height: 15)
        }
    }

    func update(snapshot: OPNStreamStatsSnapshot, gameTitle: String, backendName: String) {
        titleLabel.stringValue = "GEFORCE NOW STATS"
        statusLabel.stringValue = snapshot.available ? "LIVE  CMD+N" : "WAITING  CMD+N"
        setValue(resolutionText(snapshot.resolution), at: 0)
        setValue(snapshot.fps > 0 ? "\(snapshot.fps) target" : "--", at: 1)
        setValue(snapshot.renderFps >= 0 ? String(format: "%.1f", snapshot.renderFps) : "--", at: 2)
        setValue(snapshot.inboundBitrateMbps >= 0 ? String(format: "%.1f Mbps", snapshot.inboundBitrateMbps) : "--", at: 3)
        setValue(snapshot.latencyMs >= 0 ? "\(Int(snapshot.latencyMs.rounded())) ms" : "--", at: 4)
        setValue(snapshot.jitterMs >= 0 ? "\(Int(snapshot.jitterMs.rounded())) ms" : "--", at: 5)
        setValue(snapshot.packetLossPercent >= 0 ? String(format: "%.2f%%", snapshot.packetLossPercent) : "--", at: 6)
        setValue("\(snapshot.framesDropped + snapshot.videoEnhancementDroppedFrames)", at: 7)
        setValue(codecText(snapshot.codec, backendName: backendName), at: 8)
        setValue(enhancementText(snapshot.videoEnhancementActiveTier), at: 9)
    }

    private func initialize() {
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.backgroundColor = NSColor(calibratedWhite: 0.015, alpha: 0.82).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow?.shadowBlurRadius = 18
        shadow?.shadowOffset = NSSize(width: 0, height: -6)
        addSubview(titleLabel)
        addSubview(statusLabel)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Self.green.withAlphaComponent(0.72).cgColor
        addSubview(separator)
        rows.forEach { row in
            addSubview(row.title)
            addSubview(row.value)
        }
    }

    private func setValue(_ value: String, at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].value.stringValue = value.isEmpty ? "--" : value
    }

    private func resolutionText(_ resolution: String) -> String {
        resolution.isEmpty ? "--" : resolution.replacingOccurrences(of: "x", with: " x ")
    }

    private func codecText(_ codec: String, backendName: String) -> String {
        let resolvedCodec = codec.isEmpty ? "--" : codec.uppercased()
        return backendName.isEmpty ? resolvedCodec : "\(resolvedCodec) / \(backendName)"
    }

    private func enhancementText(_ value: String) -> String {
        value.isEmpty ? "Off" : value.replacingOccurrences(of: "_", with: " ")
    }

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private static let green = NSColor(calibratedRed: 0.463, green: 0.725, blue: 0, alpha: 1)
}

@MainActor
private final class OPNGFNStatsHUDRow {
    let title: NSTextField
    let value: NSTextField

    init(label: String) {
        title = OPNGFNStatsHUDView.makeRowTitle(label)
        value = OPNGFNStatsHUDView.makeRowValue()
    }
}

private extension OPNGFNStatsHUDView {
    static func makeRowTitle(_ text: String) -> NSTextField {
        let label = makeLabel(size: 10, weight: .medium, color: NSColor(calibratedWhite: 0.56, alpha: 1))
        label.stringValue = text
        return label
    }

    static func makeRowValue() -> NSTextField {
        let label = makeLabel(size: 10, weight: .semibold, color: NSColor(calibratedWhite: 0.93, alpha: 1))
        label.alignment = .right
        label.stringValue = "--"
        return label
    }
}
