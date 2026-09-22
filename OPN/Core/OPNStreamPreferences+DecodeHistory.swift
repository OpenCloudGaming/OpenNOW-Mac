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

    /// Every measurement recorded at `resolution` with `codec`, keyed by colour tier. Only the
    /// tiers this build offers are returned: the store is an append-only dictionary that test
    /// sessions and superseded tiers also write to, and an unrecognised tier has no label to show.
    public static func decodeMeasurements(resolution: String, codec: String) -> [String: DecodeMeasurement] {
        guard let all = storage.dictionary(forKey: k.decodeMeasurements) else { return [:] }
        let known = Set(colorQualityOptions.map { $0.value.lowercased() })
        let prefix = "\(codec.uppercased())|\(resolution.lowercased())|"
        var result: [String: DecodeMeasurement] = [:]
        for key in all.keys where key.hasPrefix(prefix) {
            let tier = String(key.dropFirst(prefix.count))
            guard known.contains(tier), let measurement = decodeMeasurement(for: key) else { continue }
            result[tier] = measurement
        }
        return result
    }

    /// Settings' "Recommended for this Mac" report for a resolution and codec: every colour tier
    /// measured there, in order of decode cost, each with the frame rate its decode time fits.
    /// Pure over the records it is given so it can be tested.
    public static func decodeRecommendation(resolution: String, codec: String, targetFps: Int, records: [String: DecodeMeasurement], labels: [String: String]) -> DecodeRecommendation? {
        let tiers = records.compactMap { key, measurement -> DecodeRecommendation.Tier? in
            guard let label = labels[key] else { return nil }
            return DecodeRecommendation.Tier(key: key,
                                             label: label,
                                             decodeMilliseconds: measurement.decodeMilliseconds,
                                             sustainableFps: measurement.sustainableFps,
                                             targetFps: targetFps)
        }.sorted { $0.decodeMilliseconds < $1.decodeMilliseconds }
        guard !tiers.isEmpty else { return nil }
        return DecodeRecommendation(resolution: resolution, codec: codec.uppercased(), targetFps: targetFps, tiers: tiers)
    }

    public static func decodeRecommendation(resolution: String, codec: String, targetFps: Int) -> DecodeRecommendation? {
        let labels = Dictionary(uniqueKeysWithValues: colorQualityOptions.map { ($0.value.lowercased(), $0.label) })
        return decodeRecommendation(resolution: resolution, codec: codec, targetFps: targetFps,
                                    records: decodeMeasurements(resolution: resolution, codec: codec), labels: labels)
    }

    /// What this Mac measured while decoding one resolution/codec, one entry per colour tier.
    public struct DecodeRecommendation: Equatable, Sendable {
        public struct Tier: Equatable, Sendable, Identifiable {
            public var id: String { key }
            public let key: String
            public let label: String
            public let decodeMilliseconds: Double
            public let sustainableFps: Int
            public let targetFps: Int

            public var holdsTargetFps: Bool { sustainableFps >= targetFps }
            public var millisecondsText: String { String(format: "%.1f ms", decodeMilliseconds) }
            public var verdictText: String {
                holdsTargetFps ? "holds \(targetFps) fps" : "fits ~\(sustainableFps) fps"
            }
        }

        public let resolution: String
        public let codec: String
        public let targetFps: Int
        public let tiers: [Tier]
    }

    /// One line for Settings: what the chosen combination decoded at on this Mac, and what frame
    /// rate that fits, or that it has not been measured yet.
    public static func decodeAdvice(codec: String, resolution: String, colorQualityLabel: String, colorQuality: String, fps: Int) -> String {
        guard let measurement = decodeMeasurement(for: streamShapeKey(codec: codec, resolution: resolution, colorQuality: colorQuality)) else {
            return "Not measured yet on this Mac. Stream once at these settings."
        }
        let fits = measurement.sustainableFps
        let verdict = fits >= fps ? "holds \(fps) fps" : "fits about \(fits) fps, not \(fps)"
        return String(format: "%.1f ms per frame at %@ %@ (%@); %@.", measurement.decodeMilliseconds, resolution, colorQualityLabel, codec.uppercased(), verdict)
    }
}
