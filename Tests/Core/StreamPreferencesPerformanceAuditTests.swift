import Foundation
import Testing
@testable import OpenNOW

private struct CommonPerformanceAuditMeasurement: Encodable {
    let package: String
    let operation: String
    let iterations: Int
    let totalMilliseconds: Double
    let meanMilliseconds: Double
    let minMilliseconds: Double
    let maxMilliseconds: Double
}

private struct CommonPerformanceAuditOutput: Encodable {
    let generatedAt: String
    let measurements: [CommonPerformanceAuditMeasurement]
}

@Test func streamPreferencesPerformanceAudit() throws {
    guard ProcessInfo.processInfo.environment["OPENNOW_PERF_AUDIT"] == "1" else { return }

    let measurements = [
        measureCommonAuditOperation(operation: "OPNStreamPreferences.loadDeviceCapabilities", iterations: 200) {
            _ = OPNStreamPreferences.loadDeviceCapabilities()
        },
        measureCommonAuditOperation(operation: "OPNStreamPreferences.loadMicrophoneDeviceOptions", iterations: 100) {
            _ = OPNStreamPreferences.loadMicrophoneDeviceOptions()
        },
        measureCommonAuditOperation(operation: "OPNStreamPreferences.loadProfile/effectiveProfile", iterations: 1_000) {
            let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
            _ = OPNStreamPreferences.effectiveProfile(OPNStreamPreferences.loadProfile(), capabilities: capabilities)
        },
    ]

    let output = CommonPerformanceAuditOutput(generatedAt: ISO8601DateFormatter().string(from: Date()), measurements: measurements)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(output)
    if let outputPath = ProcessInfo.processInfo.environment["OPENNOW_PERF_AUDIT_OUTPUT"], !outputPath.isEmpty {
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
    print(String(decoding: data, as: UTF8.self))
}

private func measureCommonAuditOperation(operation: String, iterations: Int, body: () -> Void) -> CommonPerformanceAuditMeasurement {
    var durations: [Double] = []
    durations.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let end = DispatchTime.now().uptimeNanoseconds
        durations.append(Double(end - start) / 1_000_000)
    }
    let total = durations.reduce(0, +)
    return CommonPerformanceAuditMeasurement(
        package: "OPN.Common",
        operation: operation,
        iterations: iterations,
        totalMilliseconds: total,
        meanMilliseconds: total / Double(iterations),
        minMilliseconds: durations.min() ?? 0,
        maxMilliseconds: durations.max() ?? 0
    )
}
