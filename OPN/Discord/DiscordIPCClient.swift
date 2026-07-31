import Foundation
import Darwin

actor DiscordIPCClient {
    private enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
    }

    private let clientID: String
    private var fd: Int32 = -1

    init(clientID: String) {
        self.clientID = clientID
    }

    var isConnected: Bool { fd >= 0 }

    @discardableResult
    func connectIfNeeded() -> Bool {
        if fd >= 0 { return true }
        guard let socketFd = openSocket() else { return false }
        fd = socketFd
        let handshake: [String: Any] = ["v": 1, "client_id": clientID]
        guard sendFrame(op: .handshake, json: handshake) else {
            disconnect()
            return false
        }
        _ = readFrame()
        return true
    }

    func setActivity(_ activity: DiscordActivity?, pid: Int32) {
        guard connectIfNeeded() else { return }
        drainIncoming()
        var args: [String: Any] = ["pid": Int(pid)]
        if let activity {
            args["activity"] = activity.jsonObject()
        } else {
            args["activity"] = NSNull()
        }
        let command: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": args,
            "nonce": UUID().uuidString
        ]
        if !sendFrame(op: .frame, json: command) {
            disconnect()
        }
    }

    func disconnect() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    private func openSocket() -> Int32? {
        for index in 0...9 {
            let path = (Self.ipcDirectory as NSString)
                .appendingPathComponent("discord-ipc-\(index)")
            if let fd = connectSocket(path: path) { return fd }
        }
        return nil
    }

    private func connectSocket(path: String) -> Int32? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let didFit = path.withCString { cString -> Bool in
            let length = strlen(cString)
            guard length < capacity else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
                rawPtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    _ = memcpy(dst, cString, length + 1)
                }
            }
            return true
        }
        guard didFit else { close(sock); return nil }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { rawPtr in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                Darwin.connect(sock, addrPtr, size)
            }
        }
        guard result == 0 else { close(sock); return nil }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return sock
    }

    private static var ipcDirectory: String {
        for key in ["TMPDIR", "TMP", "TEMP", "XDG_RUNTIME_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                return value
            }
        }
        return "/tmp"
    }

    private func sendFrame(op: Opcode, json: [String: Any]) -> Bool {
        guard fd >= 0,
              let body = try? JSONSerialization.data(withJSONObject: json)
        else { return false }

        var header = Data(capacity: 8)
        withUnsafeBytes(of: op.rawValue.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { header.append(contentsOf: $0) }
        return writeAll(header) && writeAll(body)
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let written = write(fd, base + offset, data.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    @discardableResult
    private func readFrame() -> (op: UInt32, body: Data)? {
        guard let header = readExactly(8) else { return nil }
        let op = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let body = length > 0 ? readExactly(Int(length)) : Data()
        guard let body else { return nil }
        return (op, body)
    }

    private func readExactly(_ count: Int) -> Data? {
        var buffer = Data(count: count)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var offset = 0
            while offset < count {
                let read = recv(fd, base + offset, count - offset, 0)
                if read <= 0 { return false }
                offset += read
            }
            return true
        }
        return ok ? buffer : nil
    }

    private func drainIncoming() {
        guard fd >= 0 else { return }
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = recv(fd, &scratch, scratch.count, MSG_DONTWAIT)
            if read <= 0 { break }
        }
    }
}
