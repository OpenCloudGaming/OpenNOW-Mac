//  Reading text off a captured stream frame, on device.
//

import CoreGraphics
import Foundation
import Vision

/// One candidate line Vision recognized. `bounds` is Vision's normalized box.
struct StreamRecognizedLine: Equatable, Sendable {
    let text: String
    let confidence: Float
    let bounds: CGRect

    init(text: String, confidence: Float, bounds: CGRect = .zero) {
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
    }
}

/// What a capture read, and whether a selection narrowed it.
struct StreamTextRecognition: Equatable, Sendable {
    let text: String
    let isSelectionUsed: Bool
}

/// Drops game-HUD noise before it becomes an entry: low confidence, and runs too short to be text.
enum StreamTextCaptureFilter {
    static let minimumConfidence: Float = 0.35
    static let minimumLength = 3
    /// How much of a block has to be text before it counts as a highlight rather than chrome.
    static let minimumInkCoverage: CGFloat = 0.35
    /// The shortest run two reads must share before they are treated as one string.
    static let minimumMergeOverlap = 3
    /// Longest-first overlap search; the cap only bounds the scan.
    static let maximumMergeScan = 2_000

    /// The text worth filing, joined in the order Vision returned the lines.
    static func acceptedText(from lines: [StreamRecognizedLine]) -> String {
        lines
            .filter { $0.confidence >= minimumConfidence }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minimumLength }
            .joined(separator: "\n")
    }

    /// Blocks in reading order: top of the frame first.
    static func readingOrder(_ rects: [CGRect]) -> [CGRect] {
        rects.sorted { $0.maxY > $1.maxY }
    }

    /// Whether a block is a highlight *behind* text rather than chrome with a small label on it.
    ///
    /// The block is compared with the text inside it, not with the whole line Vision reported — a
    /// partial selection is a narrow block on part of a long line. What is left to reject is
    /// proportion: a button is several times its own label.
    static func isTextSelection(_ block: CGRect, lines: [StreamRecognizedLine]) -> Bool {
        guard let inkBounds = inkBounds(inside: block, lines: lines) else { return false }
        let blockArea = block.width * block.height
        guard blockArea > 0 else { return false }
        let inkCoverage = (inkBounds.width * inkBounds.height) / blockArea
        guard inkCoverage >= minimumInkCoverage else { return false }
        return block.height / inkBounds.height <= 2.5 && block.width / inkBounds.width <= 2.0
    }

    /// Whether the text stops as if a field cut it off. Characters past an ellipsis were never
    /// rendered, so no capture-side change can recover them.
    static func isClipped(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.hasSuffix("\u{2026}") || trimmedText.hasSuffix("...")
    }

    /// Joins two reads of one clipped string when they demonstrably overlap, and nil when they do
    /// not: a page-scrolled field can leave a gap no two fragments can fill.
    static func mergedOverlap(_ first: String, _ second: String) -> String? {
        guard !first.isEmpty, !second.isEmpty else { return nil }
        if first == second { return first }
        if first.hasSuffix(second) { return first }
        if second.hasSuffix(first) { return second }
        let maximumOverlap = min(first.count, second.count, maximumMergeScan)
        guard maximumOverlap >= minimumMergeOverlap else { return nil }
        for overlapLength in stride(from: maximumOverlap, through: minimumMergeOverlap, by: -1) {
            let tailOfFirst = first.suffix(overlapLength)
            let headOfSecond = second.prefix(overlapLength)
            if tailOfFirst == headOfSecond { return first + String(second.dropFirst(overlapLength)) }
            if second.suffix(overlapLength) == first.prefix(overlapLength) { return second + String(first.dropFirst(overlapLength)) }
        }
        return nil
    }

    /// The union of the recognized text that falls inside `block`.
    private static func inkBounds(inside block: CGRect, lines: [StreamRecognizedLine]) -> CGRect? {
        var bounds: CGRect?
        for line in lines {
            let intersection = block.intersection(line.bounds)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            bounds = bounds?.union(intersection) ?? intersection
        }
        return bounds
    }
}

/// Turns a captured frame into text, off the main thread so a capture never stalls video or input.
struct StreamTextRecognizer: Sendable {
    let minimumConfidence: Float

    init(minimumConfidence: Float = StreamTextCaptureFilter.minimumConfidence) {
        self.minimumConfidence = minimumConfidence
    }

    /// The recognized text, and whether a selection narrowed it. `preferredRegion` is the rectangle
    /// the reader dragged, which is read instead of anything the scanner would guess at.
    func recognizeText(in image: StreamScreenshotImage, preferredRegion: CGRect? = nil) async -> StreamTextRecognition {
        let minimumConfidence = minimumConfidence
        return await Task.detached(priority: .userInitiated) {
            Self.recognize(cgImage: image.cgImage, preferredRegion: preferredRegion, minimumConfidence: minimumConfidence)
        }.value
    }

    /// Reads the dragged rectangle when there is one, then a detected selection, and nothing else.
    ///
    /// A selection is read as its own region rather than filtered out of whole-frame lines, because
    /// Vision groups a line into one observation and that would hand back the whole line.
    nonisolated static func recognize(
        cgImage: CGImage,
        preferredRegion: CGRect? = nil,
        minimumConfidence: Float
    ) -> StreamTextRecognition {
        guard let region = preferredRegion, isUsableRegion(region) else { return recognizeDetectedSelection(cgImage: cgImage) }
        let lines = recognizeLines(cgImage: cgImage, region: inflatedSelection(region))
        return StreamTextRecognition(text: StreamTextCaptureFilter.acceptedText(from: lines), isSelectionUsed: true)
    }

    private nonisolated static func recognizeDetectedSelection(cgImage: CGImage) -> StreamTextRecognition {
        let highlights = StreamTextSelectionDetector.selectionRects(in: cgImage)
        let wholeFrameLines = recognizeLines(cgImage: cgImage, region: nil)
        let selectedBlocks = highlights.filter { StreamTextCaptureFilter.isTextSelection($0, lines: wholeFrameLines) }
        guard !selectedBlocks.isEmpty else { return StreamTextRecognition(text: "", isSelectionUsed: false) }
        let regionTexts = StreamTextCaptureFilter.readingOrder(selectedBlocks).compactMap { block -> String? in
            let lines = recognizeLines(cgImage: cgImage, region: inflatedSelection(block))
            let text = StreamTextCaptureFilter.acceptedText(from: lines)
            return text.isEmpty ? nil : text
        }
        return StreamTextRecognition(text: regionTexts.joined(separator: "\n"), isSelectionUsed: true)
    }

    private nonisolated static func isUsableRegion(_ rect: CGRect) -> Bool {
        rect.width > 0 && rect.height > 0 && rect.width <= 1 && rect.height <= 1
    }

    /// Vision wants context around a line, and a selection hugs its glyphs.
    nonisolated static func inflatedSelection(_ rect: CGRect) -> CGRect {
        let horizontalMargin = max(0.005, rect.width * 0.02)
        let verticalMargin = max(0.004, rect.height * 0.25)
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        return rect.insetBy(dx: -horizontalMargin, dy: -verticalMargin).intersection(bounds)
    }

    nonisolated static func recognizeLines(cgImage: CGImage, region: CGRect?) -> [StreamRecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let region { request.regionOfInterest = region }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            OPNLog.error(.stream, "Frame text recognition failed: \(error.localizedDescription)")
            return []
        }
        guard let observations = request.results else { return [] }
        return observations.compactMap { observation -> StreamRecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return StreamRecognizedLine(text: candidate.string, confidence: candidate.confidence, bounds: observation.boundingBox)
        }
    }
}

/// The per-session gate on repeated captures: Ctrl+C is a common gameplay binding.
struct StreamTextCaptureCooldown: Sendable {
    static let defaultInterval: TimeInterval = 2

    let interval: TimeInterval
    private var lastCaptureAt: Date?

    init(interval: TimeInterval = StreamTextCaptureCooldown.defaultInterval) {
        self.interval = interval
    }

    func allowsCapture(at date: Date) -> Bool {
        guard let lastCaptureAt else { return true }
        return date.timeIntervalSince(lastCaptureAt) >= interval
    }

    mutating func recordCapture(at date: Date) {
        lastCaptureAt = date
    }
}
