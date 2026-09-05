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
