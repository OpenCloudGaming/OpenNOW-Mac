import Foundation

enum NvstBundleAudioSDP {
    static func applyingSurroundAudio(_ sdp: String, channels: Int) -> String {
        guard let fmtp = multiopusFmtp(channels: channels) else { return sdp }
        var lines = sdpLines(sdp)
        var isAudioSection = false
        var opusPayloads = Set<Int>()
        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("m=") {
                isAudioSection = line.hasPrefix("m=audio")
                continue
            }
            guard isAudioSection, line.hasPrefix("a=rtpmap:"), let payload = payloadType(line, prefix: "a=rtpmap:") else { continue }
            let codec = String(line.dropFirst("a=rtpmap:".count)).drop { $0 != " " }.trimmingCharacters(in: .whitespaces).lowercased()
            if codec == "opus/48000/2" {
                lines[index] = "a=rtpmap:\(payload) multiopus/48000/\(channels)"
                opusPayloads.insert(payload)
            }
        }
        guard !opusPayloads.isEmpty else { return sdp }
        for index in lines.indices where lines[index].hasPrefix("a=fmtp:") {
            guard let payload = payloadType(lines[index], prefix: "a=fmtp:"), opusPayloads.contains(payload) else { continue }
            lines[index] = "a=fmtp:\(payload) \(fmtp)"
        }
        return joinSdpLinesLike(lines, original: sdp)
    }

    private static func multiopusFmtp(channels: Int) -> String? {
        switch channels {
        case 6: "minptime=10;useinbandfec=1;channel_mapping=0,4,1,2,3,5;num_streams=4;coupled_streams=2"
        case 8: "minptime=10;useinbandfec=1;channel_mapping=0,6,1,2,3,4,5,7;num_streams=5;coupled_streams=3"
        default: nil
        }
    }

    private static func payloadType(_ line: String, prefix: String) -> Int? {
        guard line.hasPrefix(prefix) else { return nil }
        let text = String(line.dropFirst(prefix.count))
        let token = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).first.map(String.init) ?? ""
        return Int(token)
    }

    private static func sdpLines(_ sdp: String) -> [String] {
        sdp.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    }

    private static func joinSdpLinesLike(_ lines: [String], original: String) -> String {
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        var text = lines.joined(separator: newline)
        if original.hasSuffix("\n"), !text.hasSuffix(newline) { text += newline }
        return text
    }
}
