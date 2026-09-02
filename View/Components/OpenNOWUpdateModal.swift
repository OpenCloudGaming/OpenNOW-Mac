import SwiftUI

/// Window-level host for the update modal. Mounted once at the app root so the prompt reaches the
/// catalog, the login wall, and the stream surface through the same path.
struct OpenNOWUpdateOverlay: View {
    @ObservedObject private var presentation = OpenNOWUpdatePresentation.shared
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        if let request = presentation.request {
            GeometryReader { proxy in
                ZStack {
                    OpenNOWDesign.Surface.scrim
                        .ignoresSafeArea()
                        .onTapGesture { presentation.dismiss() }

                    OpenNOWUpdateModal(
                        request: request,
                        notes: presentation.notes,
                        installState: presentation.installState,
                        availableSize: proxy.size,
                        uiScale: uiScale
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .transition(.opacity)
        }
    }
}

struct OpenNOWUpdateModal: View {
    let request: OpenNOWUpdatePresentation.Request
    let notes: OpenNOWReleaseNotes
    let installState: OpenNOWUpdatePresentation.InstallState
    let availableSize: CGSize
    let uiScale: CGFloat

    @ObservedObject private var presentation = OpenNOWUpdatePresentation.shared
    @Environment(\.openURL) private var openURL

    private var panelWidth: CGFloat {
        max(min(560 * uiScale, availableSize.width - OpenNOWDesign.Spacing.pageHorizontal(scale: uiScale) * 2), 280 * uiScale)
    }

    /// The notes pane is the only part allowed to grow, and only to half the window: a release with
    /// a hundred entries must scroll rather than push the footer off-screen.
    private var notesMaxHeight: CGFloat {
        max(min(340 * uiScale, availableSize.height * 0.5), 120 * uiScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            header

            Rectangle()
                .fill(OpenNOWDesign.Stroke.subtle)
                .frame(height: 1)

            body(for: request)

            Rectangle()
                .fill(OpenNOWDesign.Stroke.subtle)
                .frame(height: 1)

            footer
        }
        .frame(width: panelWidth)
        .background(OpenNOWDesign.Surface.panel)
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28 * uiScale, y: 20 * uiScale)
        .onExitCommand { presentation.dismiss() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(eyebrow)
                    .font(.nvidiaSans(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(1.1)
                Text(title)
                    .font(.nvidiaSans(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.nvidiaSans(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OpenNOWDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            OpenNOWModalCloseButton(uiScale: uiScale) { presentation.dismiss() }
                .disabled(installState.isWorking)
                .opacity(installState.isWorking ? 0.4 : 1)
        }
        .padding(.horizontal, OpenNOWDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OpenNOWDesign.Spacing.medium(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenNOWDesign.Surface.appBar)
    }

    @ViewBuilder
    private func body(for request: OpenNOWUpdatePresentation.Request) -> some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.contentVertical(scale: uiScale)) {
            switch request {
            case .available:
                ScrollView(.vertical) {
                    OpenNOWReleaseNotesView(notes: notes, metrics: .modal, uiScale: uiScale)
                        .padding(.trailing, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                }
                .frame(maxHeight: notesMaxHeight)

                if installState.isWorking {
                    installProgress
                }
            case .upToDate(let version):
                message("OpenNOW \(version) is the latest release published on GitHub.")
            case .checkFailed(let text):
                message(text)
            case .installFailed(let text):
                message(text)
            }
        }
        .padding(OpenNOWDesign.Spacing.card(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.nvidiaSans(size: 12 * uiScale, weight: .medium))
            .foregroundStyle(OpenNOWDesign.Text.secondary)
            .lineSpacing(2 * uiScale)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var installProgress: some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            HStack {
                Text(installState == .staging ? "INSTALLING" : "DOWNLOADING")
                    .font(.nvidiaSans(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
                    .tracking(1.1)
                Spacer(minLength: OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                if let byteSummary {
                    Text(byteSummary)
                        .font(.nvidiaSans(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                }
            }

            if case .downloading(let progress) = installState, let fraction = progress.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.10))
                        Rectangle()
                            .fill(OpenNOWDesign.accent)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 3 * uiScale)
            } else {
                VendorIndeterminateProgressBar()
                    .frame(height: 3 * uiScale)
            }
        }
        .padding(OpenNOWDesign.Spacing.section(scale: uiScale))
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
    }

    private var footer: some View {
        HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
            if let linkURL {
                Button {
                    openURL(linkURL)
                } label: {
                    Text(linkTitle)
                        .font(.nvidiaSans(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                        .tracking(0.8)
                }
                .buttonStyle(.opnPressable)
            }

            Spacer(minLength: OpenNOWDesign.Spacing.xSmall(scale: uiScale))

            if case .available = request {
                Button("LATER") { presentation.remindTomorrow() }
                    .help("Hides this update until tomorrow")
                    .buttonStyle(OpenNOWModalSecondaryButtonStyle(uiScale: uiScale))
                    .disabled(installState.isWorking)

                Button(installState.isWorking ? "INSTALLING" : "INSTALL AND RELAUNCH") { presentation.install() }
                    .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                    .disabled(installState.isWorking)
                    .opacity(installState.isWorking ? 0.62 : 1)
            } else {
                Button("CLOSE") { presentation.dismiss() }
                    .buttonStyle(OpenNOWModalSecondaryButtonStyle(uiScale: uiScale))
            }
        }
        .padding(.horizontal, OpenNOWDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OpenNOWDesign.Spacing.small(scale: uiScale))
    }

    private var eyebrow: String {
        switch request {
        case .available: return "UPDATE AVAILABLE"
        case .upToDate: return "UP TO DATE"
        case .checkFailed: return "UPDATE CHECK FAILED"
        case .installFailed: return "UPDATE INSTALL FAILED"
        }
    }

    private var title: String {
        switch request {
        case .available(let release): return "OpenNOW \(release.version)"
        case .upToDate: return "OpenNOW is up to date"
        case .checkFailed: return "Could not reach GitHub"
        case .installFailed: return "Update was not installed"
        }
    }

    private var subtitle: String? {
        guard case .available(let release) = request else { return nil }
        var parts = ["You're on \(SettingsAppMetadata.version)"]
        if let publishedAt = release.publishedAt {
            parts.append(OpenNOWUpdateFormat.releaseDate(publishedAt))
        }
        if release.assetByteCount > 0 {
            parts.append(OpenNOWUpdateFormat.byteCount(release.assetByteCount))
        }
        return parts.joined(separator: " · ")
    }

    private var byteSummary: String? {
        guard case .downloading(let progress) = installState, progress.expectedBytes > 0 else { return nil }
        return "\(OpenNOWUpdateFormat.byteCount(progress.receivedBytes)) / \(OpenNOWUpdateFormat.byteCount(progress.expectedBytes))"
    }

    private var linkTitle: String {
        if case .installFailed = request { return "DOWNLOAD MANUALLY" }
        return "VIEW ON GITHUB"
    }

    private var linkURL: URL? {
        switch request {
        case .available(let release):
            return notes.compareURL ?? URL(string: release.releaseURL)
        case .installFailed:
            return presentation.availableRelease.flatMap { URL(string: $0.releaseURL) }
        case .upToDate, .checkFailed:
            return nil
        }
    }
}

struct OpenNOWModalCloseButton: View {
    let uiScale: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.nvidiaSans(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(isHovering ? OpenNOWDesign.Text.primary : OpenNOWDesign.Text.secondary)
                .frame(width: 28 * uiScale, height: 28 * uiScale)
                .background(isHovering ? Color.white.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        .accessibilityLabel("Close")
    }
}

enum OpenNOWUpdateFormat {
    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func releaseDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

#if DEBUG
private struct OpenNOWUpdateModalPreview: View {
    let request: OpenNOWUpdatePresentation.Request
    var installState = OpenNOWUpdatePresentation.InstallState.idle
    var uiScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OpenNOWDesign.Surface.app
                OpenNOWDesign.Surface.scrim
                OpenNOWUpdateModal(
                    request: request,
                    notes: notes,
                    installState: installState,
                    availableSize: proxy.size,
                    uiScale: uiScale
                )
            }
        }
        .frame(width: 900 * uiScale, height: 720 * uiScale)
    }

    private var notes: OpenNOWReleaseNotes {
        guard case .available(let release) = request else { return .empty }
        return OpenNOWReleaseNotesFormatter.parse(release.releaseNotes)
    }
}

#Preview("Update available") {
    OpenNOWUpdateModalPreview(request: .available(OpenNOWUpdatePresentation.sampleRelease()))
}

#Preview("Downloading") {
    OpenNOWUpdateModalPreview(
        request: .available(OpenNOWUpdatePresentation.sampleRelease()),
        installState: .downloading(OpenNOWUpdateDownloadProgress(receivedBytes: 12_400_000, expectedBytes: 44_182_016))
    )
}

#Preview("Staging") {
    OpenNOWUpdateModalPreview(
        request: .available(OpenNOWUpdatePresentation.sampleRelease()),
        installState: .staging
    )
}

#Preview("Update available @ 1.5x") {
    OpenNOWUpdateModalPreview(request: .available(OpenNOWUpdatePresentation.sampleRelease()), uiScale: 1.5)
}

#Preview("Up to date") {
    OpenNOWUpdateModalPreview(request: .upToDate(version: "0.3.0"))
}

#Preview("Install failed") {
    OpenNOWUpdateModalPreview(request: .installFailed(message: "The downloaded app bundle did not pass macOS code-signature verification."))
}

#Preview("Release notes list") {
    ScrollView {
        OpenNOWReleaseNotesView(
            notes: OpenNOWReleaseNotesFormatter.parse(OpenNOWUpdatePresentation.sampleReleaseNotesBody),
            metrics: .settings,
            entryLimit: 5,
            uiScale: 1
        )
        .padding(24)
    }
    .frame(width: 620, height: 560)
    .background(OpenNOWDesign.Surface.panel)
}
#endif
