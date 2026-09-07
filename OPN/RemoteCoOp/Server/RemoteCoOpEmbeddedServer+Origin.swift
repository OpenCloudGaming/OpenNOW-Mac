//  Origin-allowlist and bundle helpers for the embedded Remote Co-Op server.
//
//  These are static helpers that need no actor state, split out to keep the actor body under the
//  400-line linter limit while preserving the security intent in one place.
//

import Foundation

extension OPNRemoteCoOpEmbeddedServer {

    /// Whether a browser at `origin` may open the signaling socket.
    ///
    /// A WebSocket is not subject to the same-origin policy the way `fetch` is: any page in any tab
    /// can open one to this server, and the browser will send it. The invite token gates anything
    /// meaningful, but this listener runs on the machine playing the game, so an unrelated page
    /// should not get as far as speaking the protocol.
    ///
    /// A missing `Origin` is allowed: non-browser clients omit it entirely, and the guest page is
    /// not the only legitimate client (the test harness and the smoke checks connect directly).
    static func isOriginAllowed(_ origin: String?, port: UInt16, additional: [String]) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        let normalized = origin.lowercased()
        if additional.contains(normalized) { return true }
        // Every form a browser can produce for this machine's own listener.
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            if normalized == "https://\(host):\(port)" || normalized == "https://\(host)" { return true }
        }
        // A LAN address cannot be enumerated ahead of time - the interface list can change while a
        // session is live - so any private-range host on this listener's port is accepted.
        guard let url = URL(string: normalized),
              url.scheme == "https",
              let host = url.host,
              url.port == Int(port) || url.port == nil else { return false }
        return isPrivateIPv4(host)
    }

    /// RFC 1918, link-local, and the 100.64.0.0/10 CGNAT block a tailnet addresses hosts from -
    /// every address a guest on the same network or the same VPN can reach this Mac at. Deliberately
    /// not a general "is this a LAN address" helper: a routable public address here means something
    /// is proxying, and that has to be named explicitly as a tunnel origin.
    static func isPrivateIPv4(_ host: String) -> Bool {
        // Every label has to parse, not just four of them. `compactMap` silently discarded the
        // labels that were not numbers, so `10.0.0.1.evil.com` produced `[10, 0, 0, 1]` and was
        // classified as a LAN address - a registerable domain matching a private-range prefix.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        let parts = labels.compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        // Tailscale, which is the documented way to reach a host across networks. Without it a
        // browser guest on the tailnet loaded the page and was then 403'd on the upgrade.
        case (100, 64...127): return true
        default: return false
        }
    }

    /// The guest page shipped inside the app bundle. Serving the same files the Node broker serves
    /// means the page cannot drift from the protocol the host speaks.
    public static func bundledDocumentRoot() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resources.appendingPathComponent("Resources/RemoteCoOp/browser"),
            resources.appendingPathComponent("RemoteCoOp/browser")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }
}
