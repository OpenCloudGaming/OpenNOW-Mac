//  Retunes Opus from libwebrtc's conversational defaults (~32 kbit/s mono, 20 ms packets) for a game
//  mix. Only reachable through the SDP: `RTCRtpEncodingParameters` covers video bitrate, but the Opus
//  knobs exist solely in the `fmtp` line.
//

import Foundation

public enum OPNRemoteCoOpSDPTuning {
    /// `stereo` keeps the positional mix libwebrtc would otherwise negotiate away; `minptime` with
    /// the `ptime` line below halves packet duration, taking 10 ms out of the audio path; `usedtx=0`
    /// avoids a ramp-up on the first sound after silence, whose bandwidth saving is irrelevant here.
    static let opusParameters = [
        "minptime=10",
        "useinbandfec=1",
        "stereo=1",
        "sprop-stereo=1",
        "maxaveragebitrate=256000",
        "maxplaybackrate=48000",
        "usedtx=0"
    ].joined(separator: ";")

    static let opusPacketTimeMilliseconds = 10

    /// Unrecognised descriptions pass through intact: the alternative is a session that will not
    /// negotiate at all.
    public static func tunedForGameStreaming(_ sdp: String) -> String {
        // Original terminators preserved; normalising them would rewrite every untouched line.
        var lines = sdp.components(separatedBy: "\r\n")
        let usesCRLF = lines.count > 1
        if !usesCRLF { lines = sdp.components(separatedBy: "\n") }

        guard let opusPayloadType = payloadType(named: "opus", in: lines) else { return sdp }

        // Presence must be known before the walk. SDP orders `rtpmap` before `fmtp`, so inserting at
        // the `rtpmap` *and* substituting at the `fmtp` writes it twice - malformed, and it would have
        // happened on every real offer.
        let fmtpPrefix = "a=fmtp:\(opusPayloadType) "
        let hasFmtp = lines.contains { $0.hasPrefix(fmtpPrefix) }
        let audioSection = audioSectionIndices(in: lines)
        let hasAudioPacketTime = audioSection.contains { lines[$0].hasPrefix("a=ptime:") }

        var result: [String] = []
        result.reserveCapacity(lines.count + 2)

        for (index, line) in lines.enumerated() {
            let isInAudioSection = audioSection.contains(index)
            if line.hasPrefix(fmtpPrefix) {
                result.append("a=fmtp:\(opusPayloadType) \(opusParameters)")
                continue
            }
            if line.hasPrefix("a=ptime:"), isInAudioSection {
                // Replaced, not kept: two ptime lines in one section is malformed.
                result.append("a=ptime:\(opusPacketTimeMilliseconds)")
                continue
            }
            result.append(line)
            // libwebrtc omits `fmtp` entirely when every parameter is default, so it may need
            // inserting rather than substituting.
            guard line.hasPrefix("a=rtpmap:\(opusPayloadType) ") else { continue }
            if !hasFmtp { result.append("a=fmtp:\(opusPayloadType) \(opusParameters)") }
            if !hasAudioPacketTime { result.append("a=ptime:\(opusPacketTimeMilliseconds)") }
        }
        return result.joined(separator: usesCRLF ? "\r\n" : "\n")
    }

    /// By index, not by line text: `a=ptime:` appears identically in more than one media section.
    private static func audioSectionIndices(in lines: [String]) -> Set<Int> {
        var indices: Set<Int> = []
        var isInAudioSection = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("m=") { isInAudioSection = line.hasPrefix("m=audio") }
            if isInAudioSection { indices.insert(index) }
        }
        return indices
    }

    /// Dynamic, so it cannot be hardcoded - it differs between libwebrtc builds.
    private static func payloadType(named codec: String, in lines: [String]) -> String? {
        for line in lines where line.hasPrefix("a=rtpmap:") {
            let body = line.dropFirst("a=rtpmap:".count)
            guard let separatorIndex = body.firstIndex(of: " ") else { continue }
            let payloadType = String(body[body.startIndex..<separatorIndex])
            let encoding = body[body.index(after: separatorIndex)...]
            guard encoding.lowercased().hasPrefix("\(codec.lowercased())/") else { continue }
            return payloadType
        }
        return nil
    }
}
