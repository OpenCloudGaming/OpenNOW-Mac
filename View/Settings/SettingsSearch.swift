import SwiftUI

/// Finding a setting by name. Sixty-odd controls across seven destinations is past the point where
/// remembering which tab owns a thing is reasonable, and the reader who types "surround" knows what
/// they want long before they know it lives under Audio.

struct SettingsSearchEntry: Identifiable, Equatable {
    var id: String { "\(group.rawValue)/\(sectionID ?? "-")/\(title)" }

    let title: String
    let group: CatalogSettingsGroup
    /// The card to scroll to. Nil for a destination with no section map, where opening the tab is
    /// as close as the result can get.
    let sectionID: String?
    /// What else this setting is called. The reader's word for a thing is rarely the label on it:
    /// "5.1" for Surround Sound, "proxy" for Scope, "vsync" for Cloud G-Sync.
    let keywords: [String]

    init(_ title: String, _ group: CatalogSettingsGroup, _ sectionID: String?, keywords: [String] = []) {
        self.title = title
        self.group = group
        self.sectionID = sectionID
        self.keywords = keywords
    }
}

enum SettingsSearchIndex {
    /// Every row a reader can scroll to and see, in the order the destinations appear.
    ///
    /// Two kinds of row are deliberately absent, because a result that leads to something invisible
    /// lies about where the setting is: rows that exist only inside a modal wizard, and rows that
    /// appear only once another setting is switched on. The second kind hands its words to the
    /// control that gates it, so searching "socks" still reaches the session proxy.
    static let entries: [SettingsSearchEntry] = videoEntries + audioEntries + inputEntries + recordingEntries + networkEntries + generalEntries + remoteCoOpEntries

    private static let videoEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry("Quality Preset", .video, "display", keywords: ["profile", "balanced", "competitive", "cinematic", "custom", "data saver"]),
        SettingsSearchEntry("Aspect Ratio", .video, "display", keywords: ["16:9", "21:9", "32:9", "ultrawide", "widescreen"]),
        SettingsSearchEntry("Resolution", .video, "display", keywords: ["1080p", "1440p", "4k", "5k", "size"]),
        SettingsSearchEntry("Frame Rate", .video, "display", keywords: ["fps", "60", "120", "240", "refresh"]),
        SettingsSearchEntry("Codec", .video, "colour", keywords: ["h264", "h265", "hevc", "av1", "decode"]),
        SettingsSearchEntry("Color Precision", .video, "colour", keywords: ["colour", "10-bit", "8-bit", "444", "420", "chroma", "bit depth"]),
        SettingsSearchEntry("HDR", .video, "colour", keywords: ["high dynamic range", "hdr10", "pq", "brightness"]),
        SettingsSearchEntry("SDR Color Space", .video, "colour", keywords: ["colour space", "rec709"]),
        SettingsSearchEntry("HDR Color Space", .video, "colour", keywords: ["colour space", "rec2020"]),
        SettingsSearchEntry("Maximum Bitrate", .video, "bandwidth", keywords: ["mbps", "bandwidth", "data", "quality"]),
        SettingsSearchEntry("Cloud G-Sync", .video, "advanced", keywords: ["vsync", "tearing", "variable refresh"]),
        SettingsSearchEntry("Logical Resolution Fallback", .video, "advanced", keywords: ["scaling", "retina"]),
        SettingsSearchEntry("HUD Stream", .video, "advanced", keywords: ["overlay", "metadata"]),
        SettingsSearchEntry("Power Saver", .video, "advanced", keywords: ["battery", "efficiency", "thermal"]),
        SettingsSearchEntry("MetalFX Upscaling", .video, "upscaling", keywords: ["upscale", "sharpen", "spatial", "metal"]),
        SettingsSearchEntry("Clarity", .video, "upscaling", keywords: ["sharpness", "upscale"]),
        SettingsSearchEntry("Noise Reduction", .video, "upscaling", keywords: ["denoise", "grain", "upscale"]),
        SettingsSearchEntry("Frame Pacing", .video, "presentation", keywords: ["latency", "smooth", "stutter", "vsync", "present"]),
        // Edge Dimming only exists under a fill mode that dims, so its words ride the picker that
        // decides whether it is there at all.
        SettingsSearchEntry("Pillarbox Fill", .video, "pillarbox", keywords: [
            "black bars", "letterbox", "blur", "stretch", "crop", "16:9", "edge dimming", "dim",
        ]),
        SettingsSearchEntry("Prefilter Mode", .video, "enhancement", keywords: ["sharpen", "server", "ai"]),
        SettingsSearchEntry("Prefilter Sharpness", .video, "enhancement", keywords: ["sharpen", "clarity"]),
        SettingsSearchEntry("Prefilter Denoise", .video, "enhancement", keywords: ["noise", "grain"]),
    ]

    private static let audioEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry("Game Volume", .audio, "output", keywords: ["loudness", "sound", "mute"]),
        SettingsSearchEntry("Surround Sound", .audio, "output", keywords: ["5.1", "7.1", "multichannel", "spatial", "speakers"]),
        SettingsSearchEntry("Headphone Surround", .audio, "output", keywords: ["binaural", "spatial", "headphones", "airpods", "7.1", "5.1"]),
        SettingsSearchEntry("Microphone Mode", .audio, "microphone", keywords: ["mic", "push to talk", "voice", "open mic"]),
        SettingsSearchEntry("Microphone Device", .audio, "microphone", keywords: ["mic", "input device"]),
        SettingsSearchEntry("Microphone Volume", .audio, "microphone", keywords: ["mic", "gain", "loudness"]),
        SettingsSearchEntry("Microphone Test", .audio, "microphone", keywords: ["mic", "level", "meter", "check"]),
    ]

    private static let inputEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry("Direct Mouse Input", .input, "mouse", keywords: ["pointer", "capture", "relative", "raw"]),
        SettingsSearchEntry("Mouse Sensitivity", .input, "mouse", keywords: ["pointer", "speed", "dpi"]),
        SettingsSearchEntry("Suppress Input When Inactive", .input, "mouse", keywords: ["focus", "background", "keyboard"]),
        SettingsSearchEntry("Anti-AFK Mouse Movement", .input, "mouse", keywords: ["idle", "timeout", "disconnect", "away"]),
        SettingsSearchEntry("Controller Mode", .input, "mode", keywords: ["tv", "big picture", "gamepad", "interface"]),
        SettingsSearchEntry("Steam Controller Support", .input, "steam-controller", keywords: ["valve", "hid", "gamepad", "triton"]),
        SettingsSearchEntry("Rumble Intensity", .input, "steam-controller", keywords: ["haptics", "vibration", "force feedback"]),
    ]

    private static let networkEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry("Cloudmatch Region", .network, "server-location", keywords: ["server", "location", "latency", "ping", "zone", "country"]),
        SettingsSearchEntry("Native/NVST Transport", .network, "transport", keywords: ["nvst", "webrtc", "protocol", "rtsp"]),
        SettingsSearchEntry("L4S", .network, "transport", keywords: ["latency", "congestion", "ecn", "low latency"]),
        SettingsSearchEntry("Prevent Display Sleep", .network, "transport", keywords: ["screensaver", "idle", "awake"]),
        // The proxy's own fields appear only once it is switched on, so the toggle carries their
        // words. A result has to lead to something the reader can see.
        SettingsSearchEntry("Session Proxy", .network, "proxy", keywords: [
            "socks", "http", "vpn", "region unlock", "tunnel", "protocol", "host", "port",
            "username", "password", "credentials", "scope",
        ]),
    ]

    private static let generalEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry("Interface Scale", .general, "interface", keywords: ["ui", "size", "zoom", "text size", "5k"]),
        SettingsSearchEntry("When the Stream Is Ready", .general, "session-ready", keywords: ["notification", "alert", "queue", "bring to front", "focus"]),
        SettingsSearchEntry("Rich Presence", .general, "discord", keywords: ["discord", "status", "friends", "profile"]),
        SettingsSearchEntry("Automatic Update Checks", .general, "about", keywords: ["update", "version", "release", "upgrade"]),
        SettingsSearchEntry("Disable Telemetry", .general, "about", keywords: ["privacy", "analytics", "sentry", "tracking", "diagnostics"]),
    ]

    private static let recordingEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry("Video Bitrate", .recording, "recording", keywords: ["record", "capture", "quality", "file size"]),
        SettingsSearchEntry("Audio Bitrate", .recording, "recording", keywords: ["record", "capture", "sound"]),
        SettingsSearchEntry("Record Enhanced Video", .recording, "recording", keywords: ["record", "capture", "upscaled", "metalfx"]),
        SettingsSearchEntry("Your recordings", .recording, "library", keywords: ["library", "clips", "trim", "crop", "export", "browse"]),
    ]

    private static let remoteCoOpEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry("Enable Remote Co-Op", .remoteCoOp, nil, keywords: ["couch", "friend", "share", "invite", "multiplayer"]),
        SettingsSearchEntry("Require Host Approval", .remoteCoOp, nil, keywords: ["guest", "join", "permission"]),
        SettingsSearchEntry("Hide Guest Invite Details", .remoteCoOp, nil, keywords: ["invite", "privacy", "link"]),
        SettingsSearchEntry("Reserved Controllers", .remoteCoOp, nil, keywords: ["guest", "gamepad", "slots", "players"]),
        SettingsSearchEntry("Guest Quality", .remoteCoOp, nil, keywords: ["bitrate", "resolution", "relay"]),
        SettingsSearchEntry("Latency Mode", .remoteCoOp, nil, keywords: ["guest", "delay", "buffer"]),
        SettingsSearchEntry("Transport", .remoteCoOp, nil, keywords: ["guest", "relay", "turn", "direct", "webrtc"]),
        SettingsSearchEntry("Public Address", .remoteCoOp, nil, keywords: ["hosting", "invite", "url", "tailscale", "tunnel"]),
        SettingsSearchEntry("Ably API Key", .remoteCoOp, nil, keywords: ["signaling", "broker", "hosted"]),
        SettingsSearchEntry("Static Guest Page (Optional)", .remoteCoOp, nil, keywords: ["hosting", "invite", "page"]),
    ]

    /// Case- and diacritic-insensitive substring match over the title first, then the keywords, so a
    /// reader who types the label sees it above rows that merely mention the word.
    static func results(for query: String, limit: Int = 8) -> [SettingsSearchEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        let titleMatches = entries.filter { $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let keywordMatches = entries.filter { entry in
            guard !titleMatches.contains(entry) else { return false }
            return entry.keywords.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return Array((titleMatches + keywordMatches).prefix(limit))
    }

    /// Where a result says it lives, for the line under its title.
    static func location(of entry: SettingsSearchEntry) -> String {
        guard let sectionID = entry.sectionID,
              let section = sections(for: entry.group).first(where: { $0.id == sectionID }) else {
            return entry.group.title
        }
        return "\(entry.group.title) › \(section.title)"
    }

    static func sections(for group: CatalogSettingsGroup) -> [SettingsSection] {
        switch group {
        case .account: AccountSettingsGroup.sections
        case .video: VideoSettingsGroup.sections
        case .audio: AudioSettingsPage.sections
        case .input: InputSettingsGroup.sections
        case .recording: RecordingSettingsGroup.sections
        case .network: NetworkSettingsGroup.sections
        case .remoteCoOp: []
        case .general: GeneralSettingsGroup.sections
        case .labs: LabsSettingsPage.sections
        }
    }
}

// MARK: - Field

struct SettingsSearchField: View {
    @Binding var query: String
    let uiScale: CGFloat

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8 * uiScale) {
            Image(systemName: "magnifyingglass")
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(isFocused ? 0.72 : 0.42))
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .focused($isFocused)
                .onSubmit { isFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark")
                        .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10 * uiScale)
        .frame(height: 30 * uiScale)
        .background(Color.white.opacity(0.07))
        .overlay {
            Rectangle().strokeBorder(isFocused ? OpenNOWDesign.accent.opacity(0.44) : Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

// MARK: - Results

struct SettingsSearchResults: View {
    let results: [SettingsSearchEntry]
    let query: String
    let uiScale: CGFloat
    let action: (SettingsSearchEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * uiScale) {
            if results.isEmpty {
                Text("No setting matches \u{201C}\(query)\u{201D}.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14 * uiScale)
                    .padding(.vertical, 10 * uiScale)
            } else {
                ForEach(results) { entry in
                    SettingsSearchResultRow(entry: entry, uiScale: uiScale) { action(entry) }
                }
            }
        }
    }
}

struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry
    let uiScale: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                Text(entry.title)
                    .font(.settingsNvidia(size: 12.5 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovering ? 1 : 0.88))
                    .lineLimit(1)
                Text(SettingsSearchIndex.location(of: entry))
                    .font(.settingsNvidia(size: 10.5 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14 * uiScale)
            .padding(.vertical, 8 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.white.opacity(0.06) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isHovering ? OpenNOWDesign.accent : .clear)
                    .frame(width: 3 * uiScale)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}
