import Darwin
import Foundation

@objcMembers
@objc(OPNDiscordPresence)
final class OPNDiscordPresence: NSObject, @unchecked Sendable {
    private static let presenceModeKey = "OpenNOW.Discord.PresenceMode"
    private static let clientIdKey = "OpenNOW.Discord.ClientId"
    private static let queue = DispatchQueue(label: "io.opencg.opennow.discord-presence")

    nonisolated(unsafe) private static var startedAtUnixSeconds: Int64 = 0
    nonisolated(unsafe) private static var connectionFd: Int32 = -1
    nonisolated(unsafe) private static var connectedClientId = ""

    static func updateBrowsing() {
        let mode = loadMode()
        guard mode != 0 else { return }
        setActivity(details: "Browsing cloud games", state: "OpenNOW", includeStartTimestamp: false)
    }

    @objc(updateLaunchingWithGameTitle:)
    static func updateLaunching(gameTitle: String) {
        let mode = loadMode()
        guard mode != 0 else { return }
        let details = mode == 2 && !gameTitle.isEmpty ? "Launching \(gameTitle)" : "Launching a cloud game"
        setActivity(details: details, state: "OpenNOW", includeStartTimestamp: true)
    }

    @objc(updatePlayingWithGameTitle:resolution:fps:bitrateMbps:codec:)
    static func updatePlaying(gameTitle: String, resolution: String, fps: Int, bitrateMbps: Int, codec: String) {
        let mode = loadMode()
        guard mode != 0 else { return }
        let details = mode == 2 && !gameTitle.isEmpty ? "Playing \(gameTitle)" : "Playing a cloud game"

        var state = "Streaming via OpenNOW"
        if mode == 2 {
            var quality: [String] = []
            if !resolution.isEmpty { quality.append(resolution) }
            if fps > 0 { quality.append("\(fps) FPS") }
            if !codec.isEmpty { quality.append(codec) }
            if bitrateMbps > 0 { quality.append("\(bitrateMbps) Mbps") }
            if !quality.isEmpty { state = quality.joined(separator: " · ") }
        }

        setActivity(details: details, state: state, includeStartTimestamp: true)
    }

    static func clear() {
        guard !loadClientId().isEmpty else { return }
        sendPayload(clearActivityPayload(processId: Int(getpid())), closeAfterSend: true)
        startedAtUnixSeconds = 0
    }

    @objc(saveMode:)
    static func saveMode(_ mode: Int) {
        let sanitizedMode = mode == 1 || mode == 2 ? mode : 0
        UserDefaults.standard.set(sanitizedMode, forKey: presenceModeKey)
        UserDefaults.standard.synchronize()
        if sanitizedMode == 0 { clear() }
    }

    private static func loadMode() -> Int {
        let stored = UserDefaults.standard.integer(forKey: presenceModeKey)
        return stored == 1 || stored == 2 ? stored : 0
    }

    private static func loadClientId() -> String {
        if let defaultsValue = UserDefaults.standard.string(forKey: clientIdKey), !defaultsValue.isEmpty { return defaultsValue }
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "OPNDiscordClientID") as? String, !plistValue.isEmpty { return plistValue }
        return ProcessInfo.processInfo.environment["OPN_DISCORD_CLIENT_ID"] ?? ""
    }

    private static func setActivity(details: String, state: String, includeStartTimestamp: Bool) {
        guard !loadClientId().isEmpty else { return }
        if includeStartTimestamp && startedAtUnixSeconds <= 0 { startedAtUnixSeconds = currentUnixSeconds() }
        let startedAt = includeStartTimestamp ? startedAtUnixSeconds : 0
        sendPayload(activityPayload(details: details, state: state, startedAtUnixSeconds: startedAt, processId: Int(getpid())), closeAfterSend: false)
    }

    private static func sendPayload(_ payload: String, closeAfterSend: Bool) {
        let clientId = loadClientId()
        guard !clientId.isEmpty, !payload.isEmpty else { return }

        queue.async {
            guard ensureConnection(clientId: clientId) else { return }
            var ok = sendFrame(opcode: 1, payload: payload)
            var opcode: UInt32 = 0
            var response = ""
            if ok { ok = readFrame(opcode: &opcode, payload: &response) && opcode == 1 }
            if !ok {
                NSLog("[DiscordPresence] Failed Discord SET_ACTIVITY opcode=\(opcode) response=\(response)")
                disconnect()
                return
            }
            if closeAfterSend { disconnect() }
        }
    }

    private static func ensureConnection(clientId: String) -> Bool {
        if connectionFd >= 0 && connectedClientId == clientId { return true }
        disconnect()

        connectionFd = connectSocket()
        guard connectionFd >= 0 else {
            NSLog("[DiscordPresence] Discord IPC socket not available")
            return false
        }

        guard sendFrame(opcode: 0, payload: handshakePayload(clientId: clientId)) else {
            NSLog("[DiscordPresence] Failed to write Discord handshake")
            disconnect()
            return false
        }

        var opcode: UInt32 = 0
        var response = ""
        guard readFrame(opcode: &opcode, payload: &response), opcode == 1, response.contains("READY") else {
            NSLog("[DiscordPresence] Discord handshake did not return READY opcode=\(opcode) response=\(response)")
            disconnect()
            return false
        }

        connectedClientId = clientId
        return true
    }

    private static func disconnect() {
        if connectionFd >= 0 {
            close(connectionFd)
            connectionFd = -1
        }
        connectedClientId = ""
    }

    private static func connectSocket() -> Int32 {
        let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        for path in candidateSocketPaths() where path.utf8.count < sunPathSize {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { continue }

            #if os(macOS)
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            #endif

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { buffer in
                    _ = strncpy(buffer, path, sunPathSize - 1)
                }
            }

            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 { return fd }
            close(fd)
        }
        return -1
    }

    private static func candidateSocketPaths() -> [String] {
        var bases: [String] = []
        func appendBase(_ value: String?) {
            guard var base = value, !base.isEmpty else { return }
            while base.count > 1 && base.last == "/" { base.removeLast() }
            if !bases.contains(base) { bases.append(base) }
        }

        appendBase(ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"])
        appendBase(ProcessInfo.processInfo.environment["TMPDIR"])
        appendBase("/tmp")
        appendBase("/var/tmp")
        appendBase("/usr/tmp")

        return bases.flatMap { base in (0..<10).map { "\(base)/discord-ipc-\($0)" } }
    }

    private static func sendFrame(opcode: UInt32, payload: String) -> Bool {
        guard connectionFd >= 0, let payloadData = payload.data(using: .utf8) else { return false }
        var header = Data()
        var opcodeValue = opcode.littleEndian
        var lengthValue = UInt32(payloadData.count).littleEndian
        withUnsafeBytes(of: &opcodeValue) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &lengthValue) { header.append(contentsOf: $0) }
        return writeAll(header) && writeAll(payloadData)
    }

    private static func readFrame(opcode: inout UInt32, payload: inout String) -> Bool {
        var header = Data(count: 8)
        guard readAll(&header) else { return false }
        let values = header.withUnsafeBytes { bytes in
            (bytes.load(fromByteOffset: 0, as: UInt32.self).littleEndian, bytes.load(fromByteOffset: 4, as: UInt32.self).littleEndian)
        }
        opcode = values.0
        let length = Int(values.1)
        guard length <= 1024 * 1024 else { return false }
        var payloadData = Data(count: length)
        guard length == 0 || readAll(&payloadData) else { return false }
        payload = String(data: payloadData, encoding: .utf8) ?? ""
        return true
    }

    private static func writeAll(_ data: Data) -> Bool {
        var remaining = data.count
        var offset = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
            while remaining > 0 {
                let written = Darwin.write(connectionFd, baseAddress.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
                remaining -= written
            }
            return true
        }
    }

    private static func readAll(_ data: inout Data) -> Bool {
        var remaining = data.count
        var offset = 0
        let isEmpty = data.isEmpty
        return data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return isEmpty }
            while remaining > 0 {
                let bytesRead = Darwin.read(connectionFd, baseAddress.advanced(by: offset), remaining)
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if bytesRead == 0 { return false }
                offset += bytesRead
                remaining -= bytesRead
            }
            return true
        }
    }

    private static func handshakePayload(clientId: String) -> String {
        jsonString(["v": 1, "client_id": clientId])
    }

    private static func activityPayload(details: String, state: String, startedAtUnixSeconds: Int64, processId: Int) -> String {
        var activity: [String: Any] = [
            "details": details,
            "assets": ["large_text": "OpenNOW"],
        ]
        if !state.isEmpty { activity["state"] = state }
        if startedAtUnixSeconds > 0 { activity["timestamps"] = ["start": startedAtUnixSeconds] }
        return jsonString([
            "cmd": "SET_ACTIVITY",
            "args": ["pid": processId, "activity": activity],
            "nonce": "\(currentUnixSeconds())-\(processId)",
        ])
    }

    private static func clearActivityPayload(processId: Int) -> String {
        jsonString([
            "cmd": "SET_ACTIVITY",
            "args": ["pid": processId, "activity": NSNull()],
            "nonce": "clear-\(currentUnixSeconds())",
        ])
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    private static func currentUnixSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}
