import Foundation

/// What this Mac learned about decoding from earlier sessions: the measured decode time per
/// resolution/colour/codec, so Settings can say which combinations hold their frame rate here.
/// Keyed by the stream shape, not the title; the seat's encoder configuration is the same for every
/// game at a given shape.
extension OPNStreamPreferences {
    public static func streamShapeKey(codec: String, resolution: String, colorQuality: String) -> String {
        "\(codec.uppercased())|\(resolution.lowercased())|\(colorQuality.lowercased())"
    }

    // MARK: Decode measurements

    public struct DecodeMeasurement: Equatable, Sendable {
        public var decodeMilliseconds: Double
        public var negotiatedFps: Int
        public var measuredAt: Date

        /// Frame rate the measured decode time could sustain if decode alone set the ceiling.
        public var sustainableFps: Int { decodeMilliseconds > 0 ? Int((1000 / decodeMilliseconds).rounded(.down)) : 0 }
    }

    public static func decodeMeasurement(for key: String) -> DecodeMeasurement? {
        guard let all = storage.dictionary(forKey: k.decodeMeasurements),
              let entry = all[key] as? [String: Any],
              let ms = (entry["ms"] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return DecodeMeasurement(decodeMilliseconds: ms,
                                 negotiatedFps: (entry["fps"] as? NSNumber)?.intValue ?? 0,
                                 measuredAt: Date(timeIntervalSince1970: (entry["at"] as? NSNumber)?.doubleValue ?? 0))
    }

    /// Records a session's mean decode time. Sessions shorter than `minimumSeconds` are skipped:
    /// their mean is dominated by the start-up burst.
    public static func recordDecodeMeasurement(key: String, decodeMilliseconds: Double, negotiatedFps: Int, sessionSeconds: TimeInterval, minimumSeconds: TimeInterval = 20) {
        guard !key.isEmpty, decodeMilliseconds > 0, sessionSeconds >= minimumSeconds else { return }
        var all = storage.dictionary(forKey: k.decodeMeasurements) ?? [:]
        all[key] = ["ms": decodeMilliseconds, "fps": negotiatedFps, "at": Date().timeIntervalSince1970]
        storage.set(all, forKey: k.decodeMeasurements)
    }

    /// Every measurement recorded at `resolution` with `codec`, keyed by colour tier.
    public static func decodeMeasurements(resolution: String, codec: String) -> [String: DecodeMeasurement] {
        guard let all = storage.dictionary(forKey: k.decodeMeasurements) else { return [:] }
        let prefix = "\(codec.uppercased())|\(resolution.lowercased())|"
        var result: [String: DecodeMeasurement] = [:]
        for key in all.keys where key.hasPrefix(prefix) {
            if let measurement = decodeMeasurement(for: key) { result[String(key.dropFirst(prefix.count))] = measurement }
        }
        return result
    }

    /// Settings' "Recommended for this Mac" line for a resolution and codec: every colour tier
    /// measured there, in order of decode cost, each with the frame rate its decode time fits.
    /// Pure over the records it is given so it can be tested.
    public static func decodeRecommendation(resolution: String, codec: String, targetFps: Int, records: [String: DecodeMeasurement], labels: [String: String]) -> String? {
        guard !records.isEmpty else { return nil }
        let ordered = records.sorted { $0.value.decodeMilliseconds < $1.value.decodeMilliseconds }
        let parts = ordered.map { key, measurement -> String in
            let label = labels[key] ?? key
            let fits = measurement.sustainableFps
            return fits >= targetFps
                ? String(format: "%@ %.1f ms (holds %d)", label, measurement.decodeMilliseconds, targetFps)
                : String(format: "%@ %.1f ms (fits ~%d)", label, measurement.decodeMilliseconds, fits)
        }
        return "Measured here at \(resolution) \(codec.uppercased()): " + parts.joined(separator: " · ")
    }

    public static func decodeRecommendation(resolution: String, codec: String, targetFps: Int) -> String? {
        let labels = Dictionary(uniqueKeysWithValues: colorQualityOptions.map { ($0.value.lowercased(), $0.label) })
        return decodeRecommendation(resolution: resolution, codec: codec, targetFps: targetFps,
                                    records: decodeMeasurements(resolution: resolution, codec: codec), labels: labels)
    }

    /// One line for Settings: what the chosen combination decoded at on this Mac, and what frame
    /// rate that fits, or that it has not been measured yet.
    public static func decodeAdvice(codec: String, resolution: String, colorQualityLabel: String, colorQuality: String, fps: Int) -> String {
        guard let measurement = decodeMeasurement(for: streamShapeKey(codec: codec, resolution: resolution, colorQuality: colorQuality)) else {
            return "Not measured yet on this Mac — stream once at these settings."
        }
        let fits = measurement.sustainableFps
        let verdict = fits >= fps ? "holds \(fps) fps" : "fits about \(fits) fps, not \(fps)"
        return String(format: "%.1f ms per frame at %@ %@ (%@); %@.", measurement.decodeMilliseconds, resolution, colorQualityLabel, codec.uppercased(), verdict)
    }
}
