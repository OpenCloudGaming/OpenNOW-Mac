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
struct StreamRecognizedLine: Equatable, Sendable {
    let text: String
    let confidence: Float
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
}

/// Turns a captured frame into text. The Vision work runs off the main thread, so a capture never
/// stalls video or input.
struct StreamTextRecognizer: Sendable {
    let minimumConfidence: Float

    init(minimumConfidence: Float = StreamTextCaptureFilter.minimumConfidence) {
        self.minimumConfidence = minimumConfidence
    }

    /// The recognized text, or an empty string when the frame held nothing worth filing.
    func recognizeText(in image: StreamScreenshotImage) async -> String {
        let minimumConfidence = minimumConfidence
        return await Task.detached(priority: .userInitiated) {
            Self.recognize(cgImage: image.cgImage, minimumConfidence: minimumConfidence)
        }.value
    }

    nonisolated static func recognize(cgImage: CGImage, minimumConfidence: Float) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            OPNLog.error(.stream, "Frame text recognition failed: \(error.localizedDescription)")
            return ""
        }
        guard let observations = request.results else { return "" }
        let lines = observations.compactMap { observation -> StreamRecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return StreamRecognizedLine(text: candidate.string, confidence: candidate.confidence)
        }
        return StreamTextCaptureFilter.acceptedText(from: lines)
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
