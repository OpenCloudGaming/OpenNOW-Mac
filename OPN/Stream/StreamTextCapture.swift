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
}

/// Turns a captured frame into text. The Vision work runs off the main thread, so a capture never
/// stalls video or input.
struct StreamTextRecognizer: Sendable {
    let minimumConfidence: Float

    init(minimumConfidence: Float = StreamTextCaptureFilter.minimumConfidence) {
        self.minimumConfidence = minimumConfidence
    }

    /// The recognized text, and whether a selection narrowed it.
    func recognizeText(in image: StreamScreenshotImage) async -> StreamTextRecognition {
        let minimumConfidence = minimumConfidence
        return await Task.detached(priority: .userInitiated) {
            Self.recognize(cgImage: image.cgImage, minimumConfidence: minimumConfidence)
        }.value
    }

    /// Reads the selection when there is one, and the whole frame when there is not.
    ///
    /// Each highlight is read as its own region rather than filtering whole-frame lines after the
    /// fact: Vision groups a text line into one observation, so a reader who selects a single word
    /// would otherwise be handed the entire line the word sits on. Reading the highlighted rect
    /// itself is what makes the result the selection.
    nonisolated static func recognize(cgImage: CGImage, minimumConfidence: Float) -> StreamTextRecognition {
        let highlights = StreamTextSelectionDetector.selectionRects(in: cgImage)
        guard !highlights.isEmpty else {
            let lines = recognizeLines(cgImage: cgImage, region: nil)
            return StreamTextRecognition(
                text: StreamTextCaptureFilter.acceptedText(from: lines),
                usedSelection: false
            )
        }
        let pieces = StreamTextCaptureFilter.readingOrder(highlights).compactMap { rect -> String? in
            let lines = recognizeLines(cgImage: cgImage, region: inflatedSelection(rect))
            let text = StreamTextCaptureFilter.acceptedText(from: lines)
            return text.isEmpty ? nil : text
        }
        return StreamTextRecognition(text: pieces.joined(separator: "\n"), usedSelection: true)
    }

    /// Vision's text detector wants a little context around a line, and a highlight hugs its glyphs.
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
