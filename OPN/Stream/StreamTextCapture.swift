//  Reading text off a captured stream frame, on device. Vision needs no entitlement, no usage key
//  and no permission prompt, so the whole pipeline is local and a copy never leaves the Mac.
//
//  The filters live apart from the Vision call so they are testable without rendering a frame: the
//  recognizer feeds candidates in, and `StreamTextCaptureFilter` decides what counts as text rather
//  than game-HUD noise.
//

import CoreGraphics
import Foundation
import Vision

/// One candidate line Vision recognized, before the filter decides whether it is worth keeping.
/// `bounds` is Vision's normalized box so a line can be checked against a detected selection.
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

/// What a capture read: the text, and whether a selection narrowed it. The scope is reported rather
/// than folded away because "the whole frame" and "your selection" are very different results for
/// the same key.
struct StreamTextRecognition: Equatable, Sendable {
    let text: String
    let usedSelection: Bool
}

/// Drops game-HUD noise before it becomes a history entry. Confidence removes the confident-looking
/// garbage the recognizer sometimes returns for stylized fonts; the length floor removes the health
/// numbers, ammo counts and minimap labels a whole-frame OCR pass picks up.
enum StreamTextCaptureFilter {
    static let minimumConfidence: Float = 0.35
    static let minimumLength = 3
    /// The text worth filing, joined top-to-bottom in the order Vision returned the lines.
    static func acceptedText(from lines: [StreamRecognizedLine]) -> String {
        lines
            .filter { $0.confidence >= minimumConfidence }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minimumLength }
            .joined(separator: "\n")
    }

    /// Highlights in reading order. Vision hands whole-frame lines back top-to-bottom, and a selection
    /// read region by region has to read the same way.
    static func readingOrder(_ rects: [CGRect]) -> [CGRect] {
        rects.sorted { $0.maxY > $1.maxY }
    }

    /// Whether a detected block is a highlight *behind* text rather than a coloured panel with a
    /// label on it or a run of coloured text that happens to look solid.
    ///
    /// Colour and shape alone cannot tell them apart: a blue banner and a blue text selection are the
    /// same rectangle to the eye of a pixel scanner. The relation to the recognized text can. A
    /// selection hugs its line — roughly as tall as the line box, and wide enough to have padding
    /// each side. A button or banner is several times its label's size, and a run of coloured text has
    /// no block around it at all, so its "block" is narrower than Vision's line box.
    static func isTextSelection(_ block: CGRect, lines: [StreamRecognizedLine]) -> Bool {
        let inside = lines.filter { coverage(of: $0.bounds, by: block) >= 0.3 }
        var union: CGRect?
        for line in inside { union = union?.union(line.bounds) ?? line.bounds }
        guard let union, union.width > 0, union.height > 0 else { return false }
        let ratioH = block.height / union.height
        let ratioW = block.width / union.width
        // The bounds are generous because a selection is drawn tight: a field's highlight can be a
        // hair narrower than the line box Vision reports (measured at 0.97 on a real text field), and
        // a multilingual font can overshoot the other way. A button or banner is several times its
        // label, so the upper bounds still do the rejecting that matters.
        return ratioH >= 0.85 && ratioH <= 1.8 && ratioW >= 0.9
    }

    /// Whether the text stops as if a field cut it off. A trailing ellipsis is the one clip signal a
    /// reader can see and OCR can carry out: the characters past it were never rendered, so no
    /// capture-side change can recover them and filing the fragment silently is the wrong answer.
    static func isClipped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("\u{2026}") || trimmed.hasSuffix("...")
    }

    /// The share of `bounds` that falls inside `rect`.
    static func coverage(of bounds: CGRect, by rect: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return (intersection.width * intersection.height) / (bounds.width * bounds.height)
    }
}

/// Turns a captured frame into text. The Vision work runs off the main thread, so a capture never
/// stalls video or input.
struct StreamTextRecognizer: Sendable {
    let minimumConfidence: Float

    init(minimumConfidence: Float = StreamTextCaptureFilter.minimumConfidence) {
        self.minimumConfidence = minimumConfidence
    }

    /// The recognized text, and whether a selection narrowed it.
    ///
    /// `preferredRegion` is the rectangle the reader dragged over: when it is present the capture is
    /// read from exactly there and nothing else is consulted, because a selection the reader made by
    /// hand is a better answer than any highlight the scanner would guess at.
    func recognizeText(in image: StreamScreenshotImage, preferredRegion: CGRect? = nil) async -> StreamTextRecognition {
        let minimumConfidence = minimumConfidence
        return await Task.detached(priority: .userInitiated) {
            Self.recognize(cgImage: image.cgImage, preferredRegion: preferredRegion, minimumConfidence: minimumConfidence)
        }.value
    }

    /// Reads the dragged rectangle when there is one, then a detected selection, and the whole frame
    /// when there is neither.
    ///
    /// A selection is read as its own region rather than filtering whole-frame lines after the fact:
    /// Vision groups a text line into one observation, so a reader who selects a single word would
    /// otherwise be handed the entire line the word sits on. Reading the region itself is what makes
    /// the result the selection.
    nonisolated static func recognize(
        cgImage: CGImage,
        preferredRegion: CGRect? = nil,
        minimumConfidence: Float
    ) -> StreamTextRecognition {
        if let region = preferredRegion, isUsableRegion(region) {
            let lines = recognizeLines(cgImage: cgImage, region: inflatedSelection(region))
            return StreamTextRecognition(
                text: StreamTextCaptureFilter.acceptedText(from: lines),
                usedSelection: true
            )
        }
        let highlights = StreamTextSelectionDetector.selectionRects(in: cgImage)
        let wholeFrameLines = recognizeLines(cgImage: cgImage, region: nil)
        // A block only counts as a selection when the text it holds fits inside it like a highlight.
        // Without this the blue bars and buttons a page is full of read as selections.
        let selection = highlights.filter { StreamTextCaptureFilter.isTextSelection($0, lines: wholeFrameLines) }
        guard !selection.isEmpty else {
            // A copy is a copy of the selection. With no selection there is nothing to file — filing
            // the whole frame instead is the behaviour this feature exists to avoid, and it reads as
            // a wall of unrelated screen text.
            return StreamTextRecognition(text: "", usedSelection: false)
        }
        let pieces = StreamTextCaptureFilter.readingOrder(selection).compactMap { rect -> String? in
            let lines = recognizeLines(cgImage: cgImage, region: inflatedSelection(rect))
            let text = StreamTextCaptureFilter.acceptedText(from: lines)
            return text.isEmpty ? nil : text
        }
        return StreamTextRecognition(text: pieces.joined(separator: "\n"), usedSelection: true)
    }

    nonisolated static func isUsableRegion(_ rect: CGRect) -> Bool {
        rect.width > 0 && rect.height > 0 && rect.width <= 1 && rect.height <= 1
    }

    /// Vision's text detector wants a little context around a line, and a selection hugs its glyphs.
    /// The margin is proportional so it survives both a small chat line and a large subtitle.
    nonisolated static func inflatedSelection(_ rect: CGRect) -> CGRect {
        let dx = max(0.005, rect.width * 0.02)
        let dy = max(0.004, rect.height * 0.25)
        return rect.insetBy(dx: -dx, dy: -dy).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
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

/// The per-session gate on repeated captures. Ctrl+C is a common gameplay binding, so a held chord
/// or a burst of presses must not run a recognizer pass per frame.
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
