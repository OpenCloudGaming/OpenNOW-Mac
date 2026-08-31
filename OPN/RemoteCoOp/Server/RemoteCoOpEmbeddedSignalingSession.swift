//
//  RemoteCoOpEmbeddedSignalingSession.swift
//  OpenNOW
//
//  Adapts the locally hosted server to `OPNRemoteCoOpSignalingSession`, so the host session,
//  coordinator and peer controller are the same code whether the broker is a Node process on a
//  public address or this process.
//
//  The host half of signaling stops being a network hop entirely: there is no host WebSocket, no
//  host registration, and no host-side invite verification against a foreign secret. The events a
//  guest generates are delivered straight to the coordinator.
//

import Foundation

public final class OPNEmbeddedRemoteCoOpSignalingSession: OPNRemoteCoOpSignalingSession, @unchecked Sendable {
    private let server: OPNRemoteCoOpEmbeddedServer

    public init(server: OPNRemoteCoOpEmbeddedServer) {
        self.server = server
    }

    public func events() -> AsyncStream<OPNRemoteCoOpSignalingEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            let task = Task {
                for await event in await server.events() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ command: OPNRemoteCoOpSignalingCommand) async {
        await server.send(command)
    }

    public func close() async {
        await server.stop()
    }
}

/// Where a locally hosted session should tell guests to connect.
public enum OPNRemoteCoOpLocalAddress {
    /// The LAN address of the primary interface, or nil when there is none.
    ///
    /// A guest on this machine can use loopback, but anyone else needs the routable address, and it
    /// has to be baked into both the invite link and the certificate. Read from the interface list
    /// rather than resolved from the host name: `.local` resolution depends on the guest's mDNS
    /// working, and a certificate for a `.local` name is a second warning a guest cannot override.
    public static func primaryIPv4() -> String? {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            // en0/en1 first: on a Mac those are the built-in Ethernet and Wi-Fi, while utun and
            // bridge interfaces belong to VPNs and virtualisation and are not reachable by a guest.
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            addresses.append(String(decoding: bytes, as: UTF8.self))
        }
        return addresses.first
    }

    /// The address to advertise, preferring the LAN so a guest on another machine can reach it and
    /// falling back to loopback for same-machine testing.
    public static func advertisedHost() -> String {
        primaryIPv4() ?? "127.0.0.1"
    }
}
