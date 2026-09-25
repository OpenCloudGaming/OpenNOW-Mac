/// Platform-Specific Socket Options for QUIC
///
/// Provides compile-time platform abstractions for:
/// - **DF bit** (Don't Fragment) — required for DPLPMTUD (RFC 8899)
/// - **ECN** (Explicit Congestion Notification) — required for RFC 9000 §13.4
/// - **Interface MTU query** — initial hint for path MTU
///
/// ## Platform Matrix
///
/// | Option             | Linux constant          | macOS/iOS constant     |
/// |--------------------|-------------------------|------------------------|
/// | DF (IPv4)          | `IP_PMTUDISC_DO`        | `IP_DONTFRAG`          |
/// | DF (IPv6)          | `IPV6_DONTFRAG`         | `IPV6_DONTFRAG`        |
/// | ECN recv (IPv4)    | `IP_RECVTOS`            | `IP_RECVTOS`           |
/// | ECN recv (IPv6)    | `IPV6_RECVTCLASS`       | `IPV6_RECVTCLASS`      |
/// | ECN send (IPv4)    | `IP_TOS`                | `IP_TOS`               |
/// | ECN send (IPv6)    | `IPV6_TCLASS`           | `IPV6_TCLASS`          |
/// | Interface MTU      | `ioctl(SIOCGIFMTU)`     | `ioctl(SIOCGIFMTU)`    |
///
/// All values are exposed as `CInt` so they can be passed directly to
/// NIO `ChannelOptions.Types.SocketOption` or raw `setsockopt()` calls.

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Platform Socket Option Constants

/// Platform-resolved socket option constants for QUIC network integration.
///
/// All properties are `static let` computed at compile time via `#if os()`.
/// Call-sites use these instead of raw C constants to avoid scattering
/// `#if` blocks throughout the codebase.
public enum PlatformSocketConstants {

    // ---------------------------------------------------------------
    // MARK: Don't Fragment (DF bit)
    // ---------------------------------------------------------------

    /// Socket option level for IPv4 DF control.
    public static let ipv4DFLevel: CInt = CInt(IPPROTO_IP)

    /// Socket option name for IPv4 DF control.
    ///
    /// - Linux: `IP_MTU_DISCOVER` with value `IP_PMTUDISC_DO`
    /// - macOS/iOS: `IP_DONTFRAG` with value `1`
    #if os(Linux)
    public static let ipv4DFOption: CInt = CInt(IP_MTU_DISCOVER)
    public static let ipv4DFValue: CInt = CInt(IP_PMTUDISC_DO)
    #elseif canImport(Darwin)
    public static let ipv4DFOption: CInt = CInt(IP_DONTFRAG)
    public static let ipv4DFValue: CInt = 1
    #else
    // Unsupported platform — callers should check `isDFSupported`.
    public static let ipv4DFOption: CInt = 0
    public static let ipv4DFValue: CInt = 0
    #endif

    /// Socket option level for IPv6 DF control.
    public static let ipv6DFLevel: CInt = CInt(IPPROTO_IPV6)

    /// Socket option name for IPv6 DF control.
    ///
    /// `IPV6_DONTFRAG` is the same on Linux and Darwin.
    #if os(Linux)
    public static let ipv6DFOption: CInt = CInt(IPV6_DONTFRAG)
    #elseif canImport(Darwin)
    // IPV6_DONTFRAG is defined as 62 in <netinet6/in6.h> but not exported by Swift's Darwin module.
    public static let ipv6DFOption: CInt = CInt(62)
    #else
    public static let ipv6DFOption: CInt = 0
    #endif

    /// Value to enable IPv6 DF.
    public static let ipv6DFValue: CInt = 1

    /// Whether the current platform supports setting the DF bit.
    #if os(Linux) || canImport(Darwin)
    public static let isDFSupported: Bool = true
    #else
    public static let isDFSupported: Bool = false
    #endif

    // ---------------------------------------------------------------
    // MARK: ECN — Receive Path
    // ---------------------------------------------------------------

    /// IPv4 level for ECN options.
    public static let ipv4ECNLevel: CInt = CInt(IPPROTO_IP)

    /// IPv6 level for ECN options.
    public static let ipv6ECNLevel: CInt = CInt(IPPROTO_IPV6)

    /// Socket option to request TOS/ECN delivery on received IPv4 packets.
    ///
    /// When enabled, `recvmsg()` returns `IP_TOS` in ancillary data (cmsg).
    #if os(Linux)
    public static let ipv4RecvTOS: CInt = CInt(IP_RECVTOS)
    #elseif canImport(Darwin)
    public static let ipv4RecvTOS: CInt = CInt(IP_RECVTOS)
    #else
    public static let ipv4RecvTOS: CInt = 0
    #endif

    /// Socket option to request traffic class delivery on received IPv6 packets.
    #if os(Linux)
    public static let ipv6RecvTClass: CInt = CInt(IPV6_RECVTCLASS)
    #elseif canImport(Darwin)
    public static let ipv6RecvTClass: CInt = CInt(IPV6_RECVTCLASS)
    #else
    public static let ipv6RecvTClass: CInt = 0
    #endif

    // ---------------------------------------------------------------
    // MARK: ECN — Send Path
    // ---------------------------------------------------------------

    /// Socket option to set the TOS byte (including ECN bits) on outgoing IPv4 packets.
    #if os(Linux)
    public static let ipv4TOS: CInt = CInt(IP_TOS)
    #elseif canImport(Darwin)
    public static let ipv4TOS: CInt = CInt(IP_TOS)
    #else
    public static let ipv4TOS: CInt = 0
    #endif

    /// Socket option to set the traffic class (including ECN bits) on outgoing IPv6 packets.
    #if os(Linux)
    public static let ipv6TClass: CInt = CInt(IPV6_TCLASS)
    #elseif canImport(Darwin)
    public static let ipv6TClass: CInt = CInt(IPV6_TCLASS)
    #else
    public static let ipv6TClass: CInt = 0
    #endif

    /// Whether the current platform supports ECN socket options.
    #if os(Linux) || canImport(Darwin)
    public static let isECNSupported: Bool = true
    #else
    public static let isECNSupported: Bool = false
    #endif

    // ---------------------------------------------------------------
    // MARK: GRO / GSO (Linux only)
    // ---------------------------------------------------------------

    /// `UDP_GRO` socket option (Linux 5.0+). Zero on other platforms.
    #if os(Linux)
    // UDP_GRO = 104, not always in headers — define explicitly.
    public static let udpGRO: CInt = 104
    public static let isGROSupported: Bool = true
    #else
    public static let udpGRO: CInt = 0
    public static let isGROSupported: Bool = false
    #endif

    /// `UDP_SEGMENT` socket option for GSO (Linux 4.18+). Zero on other platforms.
    #if os(Linux)
    // UDP_SEGMENT = 103
    public static let udpSegment: CInt = 103
    public static let isGSOSupported: Bool = true
    #else
    public static let udpSegment: CInt = 0
    public static let isGSOSupported: Bool = false
    #endif

    // ---------------------------------------------------------------
    // MARK: SOL_UDP
    // ---------------------------------------------------------------

    /// `SOL_UDP` — needed for GRO/GSO options. `IPPROTO_UDP` on most platforms.
    public static let solUDP: CInt = CInt(IPPROTO_UDP)

    // ---------------------------------------------------------------
    // MARK: Interface MTU (ioctl)
    // ---------------------------------------------------------------

    /// `SIOCGIFMTU` ioctl request code, available on Linux and Darwin.
    #if os(Linux) || canImport(Darwin)
    public static let siocgifmtu: UInt = {
        #if os(Linux)
        return UInt(Glibc.SIOCGIFMTU)
        #elseif canImport(Darwin)
        // SIOCGIFMTU = _IOWR('i', 51, struct ifreq) = 0xC0206933 on Darwin (64-bit).
        // The macro is not importable through Swift's Darwin module.
        return UInt(0xC020_6933)
        #else
        return 0
        #endif
    }()
    public static let isMTUQuerySupported: Bool = true
    #else
    public static let siocgifmtu: UInt = 0
    public static let isMTUQuerySupported: Bool = false
    #endif
}

// MARK: - Socket Option Descriptor

/// A single socket option to be applied to a channel or raw fd.
///
/// Used by ``PlatformSocketOptions`` to collect the set of options
/// that should be applied to a newly created QUIC socket.
public struct SocketOptionDescriptor: Sendable, CustomStringConvertible {
    /// Socket option level (e.g. `IPPROTO_IP`, `IPPROTO_IPV6`).
    public let level: CInt

    /// Socket option name (e.g. `IP_TOS`, `IP_DONTFRAG`).
    public let name: CInt

    /// Value to set.
    public let value: CInt

    /// Human-readable label for logging.
    public let label: String

    public init(level: CInt, name: CInt, value: CInt, label: String) {
        self.level = level
        self.name = name
        self.value = value
        self.label = label
    }

    public var description: String {
        "\(label)(level=\(level), name=\(name), value=\(value))"
    }
}

// MARK: - Platform Socket Options Builder

/// Builds the set of platform-specific socket options required for a QUIC socket.
///
/// Usage:
/// ```
/// let opts = PlatformSocketOptions.forQUIC(
///     addressFamily: .ipv4,
///     enableECN: true,
///     enableDF: true
/// )
/// for opt in opts.options {
///     // apply via NIO ChannelOptions or raw setsockopt
/// }
/// ```
public struct PlatformSocketOptions: Sendable {

    /// The collected socket options.
    public let options: [SocketOptionDescriptor]

    /// Whether DF was requested and is supported.
    public let dfEnabled: Bool

    /// Whether ECN was requested and is supported.
    public let ecnEnabled: Bool

    /// Address family for which these options were built.
    public let addressFamily: AddressFamily

    public enum AddressFamily: Sendable {
        case ipv4
        case ipv6
    }

    /// Builds QUIC-appropriate socket options for the given address family.
    ///
    /// - Parameters:
    ///   - addressFamily: `.ipv4` or `.ipv6`
    ///   - enableECN: Request ECN receive/send options. Default `true`.
    ///   - enableDF: Set the Don't Fragment bit. Default `true`.
    ///   - ecnValue: Initial ECN codepoint for outgoing packets (2 low bits of TOS).
    ///     Default `0x02` (ECT(0)).
    /// - Returns: A `PlatformSocketOptions` with the resolved option descriptors.
    public static func forQUIC(
        addressFamily: AddressFamily,
        enableECN: Bool = true,
        enableDF: Bool = true,
        ecnValue: UInt8 = 0x02
    ) -> PlatformSocketOptions {
        var opts: [SocketOptionDescriptor] = []
        var dfOK = false
        var ecnOK = false

        // --- DF bit ---
        if enableDF && PlatformSocketConstants.isDFSupported {
            switch addressFamily {
            case .ipv4:
                opts.append(SocketOptionDescriptor(
                    level: PlatformSocketConstants.ipv4DFLevel,
                    name: PlatformSocketConstants.ipv4DFOption,
                    value: PlatformSocketConstants.ipv4DFValue,
                    label: "IPv4-DF"
                ))
            case .ipv6:
                opts.append(SocketOptionDescriptor(
                    level: PlatformSocketConstants.ipv6DFLevel,
                    name: PlatformSocketConstants.ipv6DFOption,
                    value: PlatformSocketConstants.ipv6DFValue,
                    label: "IPv6-DF"
                ))
            }
            dfOK = true
        }

        // --- ECN receive ---
        if enableECN && PlatformSocketConstants.isECNSupported {
            switch addressFamily {
            case .ipv4:
                opts.append(SocketOptionDescriptor(
                    level: PlatformSocketConstants.ipv4ECNLevel,
                    name: PlatformSocketConstants.ipv4RecvTOS,
                    value: 1,
                    label: "IPv4-RECVTOS"
                ))
            case .ipv6:
                opts.append(SocketOptionDescriptor(
                    level: PlatformSocketConstants.ipv6ECNLevel,
                    name: PlatformSocketConstants.ipv6RecvTClass,
                    value: 1,
                    label: "IPv6-RECVTCLASS"
                ))
            }

            // --- ECN send ---
            let tosValue = CInt(ecnValue & 0x03)
            switch addressFamily {
            case .ipv4:
                opts.append(SocketOptionDescriptor(
                    level: PlatformSocketConstants.ipv4ECNLevel,
                    name: PlatformSocketConstants.ipv4TOS,
                    value: tosValue,
                    label: "IPv4-TOS"
                ))
            case .ipv6:
                opts.append(SocketOptionDescriptor(
                    level: PlatformSocketConstants.ipv6ECNLevel,
                    name: PlatformSocketConstants.ipv6TClass,
                    value: tosValue,
                    label: "IPv6-TCLASS"
                ))
            }
            ecnOK = true
        }

        return PlatformSocketOptions(
            options: opts,
            dfEnabled: dfOK,
            ecnEnabled: ecnOK,
            addressFamily: addressFamily
        )
    }
}

// MARK: - Interface MTU Query

/// Queries the MTU of a network interface by name using `ioctl(SIOCGIFMTU)`.
///
/// - Parameter interfaceName: Interface name, e.g. `"eth0"`, `"en0"`.
/// - Returns: The interface MTU in bytes, or `nil` if the query fails
///   or the platform does not support it.
///
/// This is a **hint** for initial path MTU. Actual path MTU must be
/// confirmed via DPLPMTUD probing (RFC 8899).
public func queryInterfaceMTU(_ interfaceName: String) -> Int? {
    #if os(Linux) || canImport(Darwin)
    guard PlatformSocketConstants.isMTUQuerySupported else { return nil }

    #if os(Linux)
    let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    #endif
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var ifr = ifreq()
    let nameBytes = interfaceName.utf8CString

    // Copy interface name into the ifreq struct.
    // The name field layout differs between Linux and Darwin.
    let nameFits: Bool = withUnsafeMutablePointer(to: &ifr) { ifrPtr in
        ifrPtr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<ifreq>.size) { rawPtr in
            // ifr_name is at offset 0 on both platforms; IFNAMSIZ = 16
            let maxLen = 16
            guard nameBytes.count <= maxLen else { return false }
            for (i, byte) in nameBytes.enumerated() {
                rawPtr[i] = UInt8(bitPattern: byte)
            }
            return true
        }
    }
    guard nameFits else { return nil }

    #if os(Linux)
    let rc = ioctl(fd, UInt(Glibc.SIOCGIFMTU), &ifr)
    #else
    let rc = ioctl(fd, PlatformSocketConstants.siocgifmtu, &ifr)
    #endif

    guard rc == 0 else { return nil }

    // Extract MTU from the ifreq union.
    let mtu: Int32 = withUnsafePointer(to: &ifr) { ifrPtr in
        ifrPtr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<ifreq>.size) { rawPtr in
            // ifr_mtu sits at the same offset as ifr_ifru on both platforms,
            // which is right after ifr_name (offset 16).  It's an Int32.
            rawPtr.advanced(by: 16).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
    }
    return Int(mtu)
    #else
    return nil
    #endif
}

/// Returns the MTU for the default route interface, or `nil` if unavailable.
///
/// Iterates `getifaddrs()` to find the first non-loopback, UP interface
/// and queries its MTU. Prefer `queryInterfaceMTU(_:)` when the interface
/// name is known.
public func queryDefaultInterfaceMTU() -> Int? {
    #if os(Linux) || canImport(Darwin)
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
    defer { freeifaddrs(addrs) }

    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = current {
        let flags = UInt32(entry.pointee.ifa_flags)
        let isUp = (flags & UInt32(IFF_UP)) != 0
        let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
        let family = entry.pointee.ifa_addr?.pointee.sa_family ?? 0

        if isUp && !isLoopback && (Int32(family) == AF_INET || Int32(family) == AF_INET6) {
            let name = String(cString: entry.pointee.ifa_name)
            if let mtu = queryInterfaceMTU(name) {
                return mtu
            }
        }
        current = entry.pointee.ifa_next
    }
    return nil
    #else
    return nil
    #endif
}

// MARK: - ECN Codepoint Helpers

/// Extracts the ECN codepoint (2 low bits) from a TOS / traffic-class byte.
///
/// - Parameter tosByte: The full TOS or traffic class byte from `IP_RECVTOS`
///   or `IPV6_RECVTCLASS` ancillary data.
/// - Returns: The ECN codepoint value (0x00..0x03).
@inlinable
public func ecnFromTOS(_ tosByte: UInt8) -> UInt8 {
    tosByte & 0x03
}

/// Builds a TOS byte with the given ECN codepoint merged into the existing
/// DSCP value.
///
/// - Parameters:
///   - dscp: The current DSCP portion (upper 6 bits). Pass `0` if unknown.
///   - ecn: The ECN codepoint to set (only bits 0-1 are used).
/// - Returns: A combined TOS byte.
@inlinable
public func tosWithECN(dscp: UInt8 = 0, ecn: UInt8) -> UInt8 {
    (dscp & 0xFC) | (ecn & 0x03)
}