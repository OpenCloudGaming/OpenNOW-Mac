import Foundation

enum NativeNVSTNetworkAdjustment: Equatable, Sendable {
    case maximumBitrateKbps(UInt32)
    case dynamicStreamingMode(NativeNVSTDynamicStreamingMode)
    case l4sEnabled(Bool)
}

struct NativeNVSTNetworkGovernor: Equatable, Sendable {
    private let maximumBitrateKbps: UInt32
    private let minimumBitrateKbps: UInt32
    private(set) var currentBitrateKbps: UInt32
    private var congestionSamples = 0
    private var recoverySamples = 0
    private var l4sEnabled: Bool

    init(maximumBitrateKbps: UInt32, l4sEnabled: Bool) {
        let maximum = max(1_000, maximumBitrateKbps)
        self.maximumBitrateKbps = maximum
        minimumBitrateKbps = max(1_000, maximum * 35 / 100)
        currentBitrateKbps = maximum
        self.l4sEnabled = l4sEnabled
    }

    mutating func evaluate(_ snapshot: NativeNVSTPerformanceSnapshot) -> [NativeNVSTNetworkAdjustment] {
        guard snapshot.available else { return [] }
        let severeCongestion = snapshot.packetLoss > 0 || snapshot.jitterMilliseconds >= 35 || snapshot.latencyMilliseconds >= 120 || snapshot.bandwidthUtilizationPercent >= 95
        let congestion = severeCongestion || snapshot.frameLoss > 0 || snapshot.jitterMilliseconds >= 20 || snapshot.latencyMilliseconds >= 90
        if congestion {
            congestionSamples += 1
            recoverySamples = 0
        } else {
            recoverySamples += 1
            congestionSamples = 0
        }
        if congestionSamples >= 2, currentBitrateKbps > minimumBitrateKbps {
            currentBitrateKbps = max(minimumBitrateKbps, currentBitrateKbps * 80 / 100)
            congestionSamples = 0
            var adjustments: [NativeNVSTNetworkAdjustment] = [.maximumBitrateKbps(currentBitrateKbps), .dynamicStreamingMode(.preferFrameRate)]
            if severeCongestion, l4sEnabled {
                l4sEnabled = false
                adjustments.append(.l4sEnabled(false))
            }
            return adjustments
        }
        if recoverySamples >= 5, currentBitrateKbps < maximumBitrateKbps {
            currentBitrateKbps = min(maximumBitrateKbps, currentBitrateKbps * 110 / 100 + 1_000)
            recoverySamples = 0
            var adjustments: [NativeNVSTNetworkAdjustment] = [.maximumBitrateKbps(currentBitrateKbps)]
            if currentBitrateKbps == maximumBitrateKbps { adjustments.append(.dynamicStreamingMode(.on)) }
            return adjustments
        }
        return []
    }
}
