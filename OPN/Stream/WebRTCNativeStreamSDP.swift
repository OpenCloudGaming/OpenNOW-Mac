//
//  WebRTCNativeStreamSDP.swift
//  OpenNOW
//
//  SDP rewriting and inspection for the libwebrtc session — offer/answer munging, ICE candidate
//  rewriting, and the value coercion the session's dictionaries need. Split out of
//  WebRTCNativeStreamSession.swift.
//

import AppKit
import CoreVideo
import Darwin
import Foundation
import os
@preconcurrency import WebRTC

struct OPNStreamStatsState {
    var available = false
    var transport = "WebRTC"
    var latencyMs = -1.0
    var jitterMs = -1.0
    var inboundBitrateMbps = -1.0
    var packetLossPercent = -1.0
    var decodeTimeMs = -1.0
    var renderFps = -1.0
    var bytesReceived: UInt64 = 0
    var packetsReceived: UInt64 = 0
    var packetsLost: Int64 = 0
    var framesReceived: UInt64 = 0
    var framesDecoded: UInt64 = 0
    var framesDropped: UInt64 = 0
    var timestampMs: UInt64 = 0
    var gpuType = ""
    var zone = ""
    var resolution = ""
    var codec = ""
    var videoDecoder = "libwebrtc"
    var videoSink = "OPNMetalVideoView"
    var videoPipelineMode = "libwebrtc Metal display"
    var videoPixelFormat = "pending"
    var videoRenderMode = "pending"
    var videoFrameSource = "pending"
    var videoRenderPath = "pending"
    var videoRendererFallback = ""
    var videoEnhancementConfiguredTier = "pending"
    var videoEnhancementActiveTier = "pending"
    var videoEnhancementFallbackReason = ""
    var videoEnhancementSourceResolution = "pending"
    var videoEnhancementDrawableResolution = "pending"
    var videoEnhancementDiagnostics = ""
    var videoEnhancementFrameTimeMs = -1.0
    var videoEnhancementDroppedFrames: UInt64 = 0
    var videoFrameIntervalMs = -1.0
    var videoMaxFrameIntervalMs = -1.0
    var fps = 0
}

private func rtxAptByPayload(in sdp: String) -> [Int: Int] {
    var result: [Int: Int] = [:]
    for (payload, text) in videoFmtpByPayload(in: sdp) {
        for parameter in fmtpParameters(text) where parameter.key == "apt" {
            if let apt = Int(parameter.value) { result[payload] = apt }
        }
    }
    return result
}

private func videoPayloads(forCodec codec: String, in sdp: String) -> Set<Int> {
    var payloads = Set<Int>()
    var inVideo = false
    for line in sdpLines(sdp) {
        if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video"); continue }
        guard inVideo, line.hasPrefix("a=rtpmap:"), let payload = payloadType(line, prefix: "a=rtpmap:") else { continue }
        let upper = line.uppercased()
        switch codec {
        case "H264":
            if upper.contains(" H264/") { payloads.insert(payload) }
        case "H265":
            if upper.contains(" H265/") || upper.contains(" HEVC/") { payloads.insert(payload) }
        case "AV1":
            if upper.contains(" AV1/") { payloads.insert(payload) }
        default:
            break
        }
    }
    return payloads
}

private func videoFmtpByPayload(in sdp: String) -> [Int: String] {
    var result: [Int: String] = [:]
    var inVideo = false
    for line in sdpLines(sdp) {
        if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video"); continue }
        guard inVideo, line.hasPrefix("a=fmtp:"), let payload = payloadType(line, prefix: "a=fmtp:") else { continue }
        result[payload] = fmtpText(line)
    }
    return result
}

private func payloadType(_ line: String, prefix: String) -> Int? {
    guard line.hasPrefix(prefix) else { return nil }
    let text = String(line.dropFirst(prefix.count))
    let token = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).first.map(String.init) ?? ""
    return Int(token)
}

private func fmtpText(_ line: String) -> String {
    guard let range = line.rangeOfCharacter(from: .whitespaces) else { return "" }
    return String(line[range.upperBound...])
}

private func fmtpParameters(_ text: String) -> [(key: String, value: String)] {
    text.split(separator: ";").compactMap { item in
        let token = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let parts = token.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (key: parts[0].lowercased(), value: parts.count > 1 ? parts[1] : "")
    }
}

private func parameterValue(_ parameters: [(key: String, value: String)], _ key: String) -> String {
    parameters.first { $0.key == key.lowercased() }?.value ?? ""
}

private func setParameter(_ parameters: [(key: String, value: String)], key: String, value: String) -> [(key: String, value: String)] {
    var result = parameters
    if let index = result.firstIndex(where: { $0.key == key.lowercased() }) { result[index].value = value }
    else { result.append((key: key.lowercased(), value: value)) }
    return result
}

private func sdpLines(_ sdp: String) -> [String] {
    sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
}

private func joinSdpLinesLike(_ lines: [String], original: String) -> String {
    let newline = original.contains("\r\n") ? "\r\n" : "\n"
    var text = lines.joined(separator: newline)
    if original.hasSuffix("\n"), !text.hasSuffix(newline) { text += newline }
    return text
}

private func limitedDiagnosticText(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let end = text.index(text.startIndex, offsetBy: limit)
    return String(text[..<end]) + "...[truncated]"
}

private func sdpStableHash(_ sdp: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in sdp.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

private func videoCodecDescriptions(in sdp: String) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    var inVideo = false
    for line in sdpLines(sdp) {
        if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video"); continue }
        guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
        let text = String(line.dropFirst("a=rtpmap:".count))
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { continue }
        let codec = parts[1].split(separator: "/").first.map(String.init) ?? parts[1]
        let normalized = codec.uppercased()
        guard !seen.contains(normalized) else { continue }
        seen.insert(normalized)
        result.append(normalized)
    }
    return result
}

struct OPNIceMediaTarget { var mid = "0"; var mLineIndex: Int32 = -1 }

private func extractHost(from hostOrIp: String) -> String {
    let trimmed = hostOrIp.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), let host = url.host(percentEncoded: false), !host.isEmpty { return host }
    return trimmed.split(separator: ":").first.map(String.init) ?? trimmed
}

private func isIPv4Address(_ value: String) -> Bool {
    let parts = value.split(separator: ".")
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
        guard !part.isEmpty, let byte = Int(part), byte >= 0, byte <= 255 else { return false }
        return String(byte) == part || part == "0"
    }
}

private func dashedIPv4Prefix(from host: String) -> String? {
    let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
    let parts = firstLabel.split(separator: "-")
    guard parts.count == 4 else { return nil }
    let address = parts.joined(separator: ".")
    return isIPv4Address(address) ? address : nil
}

private func resolvedIPv4Address(for host: String) -> String? {
    var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
    defer { freeaddrinfo(result) }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var current: UnsafeMutablePointer<addrinfo>? = result
    while let info = current {
        if info.pointee.ai_family == AF_INET, let address = info.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
            var ipv4 = address.pointee.sin_addr
            if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                let length = buffer.firstIndex(of: 0) ?? buffer.count
                let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        current = info.pointee.ai_next
    }
    return nil
}

/// The SDP rewriting and value coercion the libwebrtc session shares across its extensions.
///
/// Namespaced rather than left as file-scope functions: names this generic (`string`, `int`,
/// `bool`, `extractHost`) already exist elsewhere in the module, and as internal globals they
/// would overload — or silently shadow — those.
enum WebRTCSdp {
    static func rewriteH265OfferForReceiver(_ sdp: String, maxMainLevelId: Int, maxMain10LevelId: Int, supportsHighTier: Bool) -> String {
        let h265Payloads = videoPayloads(forCodec: "H265", in: sdp)
        guard !h265Payloads.isEmpty else { return sdp }
        var lines = sdpLines(sdp)
        var changed = false
        for index in lines.indices where lines[index].hasPrefix("a=fmtp:") {
            guard let payload = payloadType(lines[index], prefix: "a=fmtp:"), h265Payloads.contains(payload) else { continue }
            var parameters = fmtpParameters(fmtpText(lines[index]))
            let profileId = Int(parameterValue(parameters, "profile-id")) ?? 1
            let maxLevel = profileId == 2 ? maxMain10LevelId : maxMainLevelId
            var lineChanged = false
            if !supportsHighTier, parameterValue(parameters, "tier-flag") == "1" {
                parameters = setParameter(parameters, key: "tier-flag", value: "0")
                lineChanged = true
            }
            let offeredLevel = Int(parameterValue(parameters, "level-id")) ?? -1
            if maxLevel > 0, offeredLevel > maxLevel {
                parameters = setParameter(parameters, key: "level-id", value: String(maxLevel))
                lineChanged = true
            }
            guard lineChanged else { continue }
            lines[index] = "a=fmtp:\(payload) " + parameters.map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }.joined(separator: ";")
            changed = true
        }
        return changed ? joinSdpLinesLike(lines, original: sdp) : sdp
    }
    static func preferCodecInOffer(_ sdp: String, normalizedCodec: String) -> String {
        let preferredPayloads = videoPayloads(forCodec: normalizedCodec, in: sdp)
        guard !preferredPayloads.isEmpty else { return sdp }
        let rtxApt = rtxAptByPayload(in: sdp)
        let rtxPayloads = Set(rtxApt.compactMap { preferredPayloads.contains($0.value) ? $0.key : nil })
        let keptPayloads = preferredPayloads.union(rtxPayloads)
        var lines = sdpLines(sdp)
        var inVideo = false
        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("m=video") {
                let parts = line.split(separator: " ").map(String.init)
                if parts.count > 3 {
                    lines[index] = Array(parts.prefix(3) + keptPayloads.sorted().map(String.init)).joined(separator: " ")
                }
                inVideo = true
                continue
            }
            if line.hasPrefix("m=") { inVideo = false; continue }
            guard inVideo else { continue }
            if let payload = payloadType(line, prefix: "a=rtpmap:"), !keptPayloads.contains(payload) { lines[index] = "" }
            else if let payload = payloadType(line, prefix: "a=fmtp:"), !keptPayloads.contains(payload) { lines[index] = "" }
            else if let payload = payloadType(line, prefix: "a=rtcp-fb:"), !keptPayloads.contains(payload) { lines[index] = "" }
        }
        return joinSdpLinesLike(lines.filter { !$0.isEmpty }, original: sdp)
    }
    static func mungeAnswerSdp(_ sdp: String, maxBitrateKbps: Int) -> String {
        let lines = sdpLines(sdp)
        var result: [String] = []
        for index in lines.indices {
            var line = lines[index]
            if line.hasPrefix("a=fmtp:"), line.contains("minptime="), !line.contains("stereo=1") { line += ";stereo=1" }
            result.append(line)
            if line.hasPrefix("m=video") || line.hasPrefix("m=audio") {
                let nextHasBandwidth = index + 1 < lines.count && lines[index + 1].hasPrefix("b=")
                if !nextHasBandwidth { result.append("b=AS:\(line.hasPrefix("m=video") ? max(1000, maxBitrateKbps) : 128)") }
            }
        }
        return joinSdpLinesLike(result, original: sdp)
    }
    static func alignH265AnswerFmtpToOffer(_ answerSdp: String, offerSdp: String) -> String {
        let answerPayloads = videoPayloads(forCodec: "H265", in: answerSdp)
        guard !answerPayloads.isEmpty else { return answerSdp }
        let offerPayloads = videoPayloads(forCodec: "H265", in: offerSdp)
        let offerFmtp = videoFmtpByPayload(in: offerSdp)
        var lines = sdpLines(answerSdp)
        var inVideo = false
        var changed = false
        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
                continue
            }
            guard inVideo, line.hasPrefix("a=fmtp:"), let payload = payloadType(line, prefix: "a=fmtp:"), answerPayloads.contains(payload), offerPayloads.contains(payload), let offerParameters = offerFmtp[payload] else { continue }
            var answerParameters = fmtpParameters(fmtpText(line))
            let offered = fmtpParameters(offerParameters)
            var lineChanged = false
            if parameterValue(answerParameters, "profile-id").isEmpty, let value = parameterValue(offered, "profile-id").nilIfEmpty { answerParameters = setParameter(answerParameters, key: "profile-id", value: value); lineChanged = true }
            if parameterValue(answerParameters, "tier-flag").isEmpty, let value = parameterValue(offered, "tier-flag").nilIfEmpty { answerParameters = setParameter(answerParameters, key: "tier-flag", value: value); lineChanged = true }
            let answerLevel = Int(parameterValue(answerParameters, "level-id")) ?? -1
            let offerLevelText = parameterValue(offered, "level-id")
            let offerLevel = Int(offerLevelText) ?? -1
            if !offerLevelText.isEmpty, parameterValue(answerParameters, "level-id").isEmpty || (answerLevel >= 0 && offerLevel > answerLevel) {
                answerParameters = setParameter(answerParameters, key: "level-id", value: offerLevelText)
                lineChanged = true
            }
            guard lineChanged else { continue }
            lines[index] = "a=fmtp:\(payload) " + answerParameters.map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }.joined(separator: ";")
            changed = true
        }
        return changed ? joinSdpLinesLike(lines, original: answerSdp) : answerSdp
    }
    static func videoSdpContainsCodec(_ sdp: String, normalizedCodec: String) -> Bool {
        !videoPayloads(forCodec: normalizedCodec, in: sdp).isEmpty
    }
    static func isTCPIceCandidate(_ candidate: String) -> Bool {
        let fields = candidate.lowercased().split(separator: " ").map(String.init)
        return fields.count > 2 && fields[2] == "tcp"
    }
    static func videoSdpHasMediaCodec(_ sdp: String) -> Bool {
        var inVideo = false
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("m=video") {
                inVideo = true
                continue
            }
            if line.hasPrefix("m="), inVideo { break }
            guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
            let upper = line.uppercased()
            if upper.contains(" H264/") || upper.contains(" H265/") || upper.contains(" HEVC/") || upper.contains(" AV1/") || upper.contains(" VP8/") || upper.contains(" VP9/") {
                return true
            }
        }
        return false
    }
    static func logVideoSdpSummary(_ label: String, _ sdp: String) {
        let message = "[LibWebRTC] \(WebRTCSdp.buildSdpMediaSummary(sdp, label: label))"
        OPNLogCapture.appendEvent(message)
    }
    static func buildSdpMediaSummary(_ sdp: String, label: String) -> String {
        var mediaLines: [String] = []
        var videoLines: [String] = []
        var inVideo = false
        for line in sdpLines(sdp) {
            if line.hasPrefix("m=") {
                mediaLines.append(line)
                inVideo = line.hasPrefix("m=video")
                if inVideo { videoLines.append(line) }
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=mid:") || line == "a=sendrecv" || line == "a=sendonly" || line == "a=recvonly" || line == "a=inactive" || line.hasPrefix("a=rtpmap:") || line.hasPrefix("a=fmtp:") || line.hasPrefix("a=rtcp-fb:") {
                videoLines.append(line)
            }
        }
        let codecs = videoCodecDescriptions(in: sdp).joined(separator: ",")
        let media = mediaLines.isEmpty ? "none" : mediaLines.joined(separator: " | ")
        let video = limitedDiagnosticText(videoLines.isEmpty ? "none" : videoLines.joined(separator: " | "), limit: 1400)
        return "\(label) hash=\(sdpStableHash(sdp)) bytes=\(sdp.utf8.count) media=\(media) videoCodecs=\(codecs.isEmpty ? "none" : codecs) video=\(video)"
    }
    static func normalizedCodec(_ codec: String) -> String {
        let upper = codec.uppercased()
        if upper == "HEVC" { return "H265" }
        if ["H264", "H265", "AV1"].contains(upper) { return upper }
        return ""
    }
    static func isSupportedCodecPreference(_ codec: String) -> Bool {
        codec == "H264" || codec == "H265" || codec == "AV1"
    }
    static func envFlagEnabled(_ name: String, defaultValue: Bool) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return defaultValue }
        let lower = value.lowercased()
        if ["0", "false", "no", "off"].contains(lower) { return false }
        if ["1", "true", "yes", "on"].contains(lower) { return true }
        return defaultValue
    }
    static func extractIceTargets(from sdp: String) -> [OPNIceMediaTarget] {
        var targets: [OPNIceMediaTarget] = []
        var index: Int32 = -1
        var currentMid = "0"
        var hasOpenMediaSection = false
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("m=") {
                if hasOpenMediaSection { targets.append(OPNIceMediaTarget(mid: currentMid, mLineIndex: index)) }
                index += 1
                currentMid = String(index)
                hasOpenMediaSection = true
            } else if hasOpenMediaSection, line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if hasOpenMediaSection { targets.append(OPNIceMediaTarget(mid: currentMid, mLineIndex: index)) }
        return targets.filter { $0.mLineIndex >= 0 && !$0.mid.isEmpty }
    }
    static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func dictionary(_ value: NSDictionary) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    static func stringArray(_ value: Any?) -> [String] { if let value = value as? String { return value.isEmpty ? [] : [value] }; if let value = value as? [String] { return value }; return (value as? NSArray)?.compactMap { WebRTCSdp.string($0) }.filter { !$0.isEmpty } ?? [] }
    static func emptyNil(_ value: String) -> String? { value.isEmpty ? nil : value }
    static func string(_ value: Any?) -> String { if let value = value as? String { return value }; if let value = value as? NSString { return value as String }; if let value = value as? NSNumber { return value.stringValue }; return "" }
    static func string(_ value: Any?, fallback: String) -> String { let text = WebRTCSdp.string(value); return text.isEmpty ? fallback : text }
    static func int(_ value: Any?, fallback: Int = 0) -> Int { if let value = value as? Int { return value }; if let value = value as? NSNumber { return value.intValue }; if let value = value as? String { return Int(value) ?? fallback }; return fallback }
    static func int64(_ value: Any?) -> Int64 { if let value = value as? Int64 { return value }; if let value = value as? NSNumber { return value.int64Value }; if let value = value as? String { return Int64(value) ?? 0 }; return 0 }
    static func uint64(_ value: Any?) -> UInt64 { if let value = value as? UInt64 { return value }; if let value = value as? NSNumber { return value.uint64Value }; if let value = value as? String { return UInt64(value) ?? 0 }; return 0 }
    static func double(_ value: Any?, fallback: Double = 0) -> Double { if let value = value as? Double { return value }; if let value = value as? NSNumber { return value.doubleValue }; if let value = value as? String { return Double(value) ?? fallback }; return fallback }
    static func clampedDouble(_ value: Any?, fallback: Double, minimum: Double, maximum: Double) -> Double { min(max(WebRTCSdp.double(value, fallback: fallback), minimum), maximum) }
    /// "#RRGGBB" to packed 0xRRGGBB. The settings dictionary carries the colour as a
    /// string, so parsing it as an Int silently yields black.
    static func packedColor(_ value: Any?) -> Int {
        guard let text = value as? String else { return 0 }
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, let packed = Int(digits, radix: 16) else { return 0 }
        return packed
    }
    static func bool(_ value: Any?) -> Bool { if let value = value as? Bool { return value }; if let value = value as? NSNumber { return value.boolValue }; if let value = value as? String { return (value as NSString).boolValue }; return false }
}

// Module-level, as they were before this file existed: these four are the SDP surface the
// stream tests exercise directly, and their names are specific enough not to collide.
func rewriteEmbeddedIceCandidates(_ sdp: String, ip: String, port: Int) -> String {
    guard !ip.isEmpty, port > 0 else { return sdp }
    let lines = sdpLines(sdp).map { line in
        if line.hasPrefix("a=candidate:") {
            return "a=" + rewriteIceCandidateLine(String(line.dropFirst(2)), ip: ip, port: port)
        }
        return line
    }
    return joinSdpLinesLike(lines, original: sdp)
}

func rewriteIceCandidateLine(_ candidate: String, ip: String, port: Int) -> String {
    guard !ip.isEmpty, port > 0 else { return candidate }
    let prefix = candidate.hasPrefix("a=") ? "a=" : ""
    let body = prefix.isEmpty ? candidate : String(candidate.dropFirst(2))
    var parts = body.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count > 5 else { return candidate }
    parts[4] = ip
    return prefix + parts.joined(separator: " ")
}

func iceUsernameFragment(fromCandidate candidate: String) -> String {
    let parts = candidate.split(separator: " ").map(String.init)
    guard let index = parts.firstIndex(of: "ufrag"), index + 1 < parts.count else { return "" }
    return parts[index + 1]
}

func extractPublicIp(_ hostOrIp: String) -> String {
    let host = extractHost(from: hostOrIp)
    guard !host.isEmpty else { return "" }
    if isIPv4Address(host) { return host }
    if let dashedAddress = dashedIPv4Prefix(from: host) { return dashedAddress }
    return resolvedIPv4Address(for: host) ?? ""
}
