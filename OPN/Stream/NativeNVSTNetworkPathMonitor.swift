import Foundation
import Network

struct NativeNVSTNetworkPath: Equatable, Sendable {
    let isSatisfied: Bool
    let usesWiFi: Bool
    let usesWiredEthernet: Bool
    let isExpensive: Bool
    let isConstrained: Bool
}

final class NativeNVSTNetworkPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "io.opencg.opennow.nvst.network-path")

    func updates() -> AsyncStream<NativeNVSTNetworkPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(NativeNVSTNetworkPath(
                    isSatisfied: path.status == .satisfied,
                    usesWiFi: path.usesInterfaceType(.wifi),
                    usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                ))
            }
            continuation.onTermination = { [monitor] _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}
