import AppKit
import CryptoKit
import SwiftUI

struct ProductSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @State private var telemetryDisabled = OPNSentry.isTelemetryDisabled()

    static let sections: [SettingsSection] = [
        SettingsSection("product", "Product"),
    ]

    var body: some View {
        SettingsCard(title: "Product", uiScale: uiScale) {
            HStack(alignment: .center, spacing: 20 * uiScale) {
                VendorResourceImage(name: "logo", fileExtension: "png")
                    .scaledToFit()
                    .frame(width: 88 * uiScale, height: 88 * uiScale)
                    .accessibilityLabel(Text("\(SettingsAppMetadata.displayName) icon"))

                VStack(alignment: .leading, spacing: 12 * uiScale) {
                    HStack(alignment: .center, spacing: 10 * uiScale) {
                        Text(SettingsAppMetadata.displayName)
                            .font(.settingsFont(size: 25 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                        Text("UNOFFICIAL CLIENT SHELL")
                            .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.onAccent)
                            .tracking(0.8)
                            .padding(.horizontal, 8 * uiScale)
                            .frame(height: 20 * uiScale)
                            .background(OPNDesign.accent)
                    }
                    Text("A macOS runtime for launching and streaming OpenNOW sessions with local catalog, account, and diagnostics surfaces.")
                        .font(.settingsFont(size: 13 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8 * uiScale) {
                        AboutStatusPill(title: "Stream", value: "NVST", uiScale: uiScale)
                        AboutStatusPill(title: "Route", value: route.summary, uiScale: uiScale)
                        AboutStatusPill(title: "Telemetry", value: telemetryDisabled ? "Off" : "On", uiScale: uiScale)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .settingsSection("product")
        .onAppear { telemetryDisabled = OPNSentry.isTelemetryDisabled() }
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: false)
    }
}

struct RuntimeSettingsPage: View {
    let uiScale: CGFloat
    @State private var copiedKey = ""

    static let sections: [SettingsSection] = [
        SettingsSection("runtime", "Runtime"),
    ]

    var body: some View {
        SettingsCard(title: "Runtime", uiScale: uiScale) {
            AboutDetailRow(label: "Version", value: SettingsAppMetadata.version, copyValue: SettingsAppMetadata.version, copiedKey: $copiedKey, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "Build", value: SettingsAppMetadata.build, copyValue: SettingsAppMetadata.build, copiedKey: $copiedKey, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "Bundle", value: bundleIdentifier, copyValue: bundleIdentifier, copiedKey: $copiedKey, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "macOS", value: operatingSystemVersion, copyValue: operatingSystemVersion, copiedKey: $copiedKey, uiScale: uiScale)
        }
        .settingsSection("runtime")
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var operatingSystemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}

/// Update preferences and the manual check in one card: everything that touches the updater lives
/// on System beside the What's New history it produces.
struct UpdatesSettingsPage: View {
    let uiScale: CGFloat
    @AppStorage(OPNUpdatePreferences.automaticUpdateChecksEnabledKey) private var automaticUpdateChecksEnabled = OPNUpdatePreferences.defaultAutomaticUpdateChecksEnabled
    @AppStorage(OPNUpdatePreferences.updateChannelKey) private var updateChannelRawValue = OPNUpdatePreferences.defaultUpdateChannel.rawValue
    @ObservedObject private var updatePresentation = OPNUpdatePresentation.shared

    static let sections: [SettingsSection] = [
        SettingsSection("updates", "Updates"),
    ]

    var body: some View {
        SettingsCard(title: "Updates", uiScale: uiScale) {
            SettingsToggleRow(title: "Automatic Update Checks", subtitle: automaticUpdateChecksSubtitle, isOn: automaticUpdateChecksEnabled, uiScale: uiScale) { enabled in
                OPNAppDelegate.setAutomaticApplicationUpdateChecksEnabled(enabled)
            }
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(
                title: "Update Channel",
                subtitle: "Beta builds come from GitHub pre-releases and may be less stable.",
                options: ["Stable", "Beta"],
                selectedIndex: updateChannel == .beta ? 1 : 0,
                uiScale: uiScale
            ) { index in
                updateChannelRawValue = (index == 1 ? OPNUpdateChannel.beta : .stable).rawValue
                OPNAppDelegate.requestApplicationUpdateCheck()
            }
            SettingsDivider(uiScale: uiScale)
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: isButtonChecking ? "CHECKING…" : "CHECK FOR UPDATES", uiScale: uiScale) {
                    OPNAppDelegate.requestApplicationUpdateCheck()
                }
                .disabled(isButtonChecking)
                Text(updateCheckStatusText)
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsSection("updates")
    }

    private var updateChannel: OPNUpdateChannel {
        OPNUpdateChannel(rawValue: updateChannelRawValue) ?? OPNUpdatePreferences.defaultUpdateChannel
    }

    private var isButtonChecking: Bool {
        #if DEBUG
        if updatePresentation.buttonStatusPreview == .checking { return true }
        #endif
        return updatePresentation.isCheckingForUpdate
    }

    private var updateCheckStatusText: String {
        #if DEBUG
        switch updatePresentation.buttonStatusPreview {
        case .checking:
            return "Checking GitHub for a newer release…"
        case .lastChecked(let date):
            return "Last checked \(date.formatted(.relative(presentation: .named)))"
        case .neverChecked:
            return "OpenNOW has not checked for updates yet."
        case nil:
            break
        }
        #endif
        if OPNUpdatePreferences.updateChecksAreSuspendedForDebugging {
            return "Update checks are suspended in debug builds, which report version 0.0.0. Test the update dialogs with OpenNOW ▸ Preview Update Dialog."
        }
        guard !updatePresentation.isCheckingForUpdate else {
            return "Checking GitHub for a newer release…"
        }
        guard let date = OPNUpdatePreferences.lastUpdateCheckDate else {
            return "OpenNOW has not checked for updates yet."
        }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }

    private var automaticUpdateChecksSubtitle: String {
        if OPNUpdatePreferences.updateChecksAreSuspendedForDebugging {
            return "Paused while running a debug build or attached debugger, which reports version 0.0.0. Use OpenNOW ▸ Preview Update Dialog to test the update UI."
        }
        if automaticUpdateChecksEnabled {
            return "Checks GitHub releases on launch and hourly while OpenNOW is running."
        }
        return "OpenNOW will not check for new releases automatically. Manual checks remain available."
    }
}

struct PrivacySettingsPage: View {
    let uiScale: CGFloat
    @State private var telemetryDisabled = OPNSentry.isTelemetryDisabled()

    static let sections: [SettingsSection] = [
        SettingsSection("privacy", "Privacy"),
    ]

    var body: some View {
        SettingsCard(title: "Privacy", uiScale: uiScale) {
            SettingsToggleRow(title: "Disable Telemetry", subtitle: "Stops Sentry, trace headers, metrics, and automatic diagnostics logging.", isOn: telemetryDisabled, uiScale: uiScale, action: setTelemetryDisabled)
        }
        .settingsSection("privacy")
        .onAppear { telemetryDisabled = OPNSentry.isTelemetryDisabled() }
    }

    private func setTelemetryDisabled(_ disabled: Bool) {
        telemetryDisabled = disabled
        OPNSentry.setTelemetryDisabled(disabled)
    }
}

struct CacheSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @State private var copiedKey = ""

    static let sections: [SettingsSection] = [
        SettingsSection("cache", "Cache"),
    ]

    var body: some View {
        SettingsCard(title: "Cache", uiScale: uiScale) {
            AboutDetailRow(label: "Catalog Images", value: viewModel.catalogImageCacheSummary, copyValue: viewModel.catalogImageCacheSummary, copiedKey: $copiedKey, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: "CLEAR IMAGE CACHE", uiScale: uiScale) {
                    viewModel.clearCatalogImageCache()
                }
                Text("Removes cached catalog artwork from disk and memory. Images will download again as needed.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
        }
        .settingsSection("cache")
        .onAppear { viewModel.refreshCatalogImageCacheSummary() }
    }
}

struct DiagnosticsSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    static let sections: [SettingsSection] = [
        SettingsSection("diagnostics", "Support Diagnostics"),
    ]

    var body: some View {
        SettingsCard(title: "Support Diagnostics", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: 10 * uiScale) {
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: diagnosticsButtonTitle, uiScale: uiScale) {
                        viewModel.presentDiagnosticsUploadConfirmation()
                    }
                    .disabled(viewModel.diagnosticsState.isWorking)
                    Text("Uploads the recent sanitized current-run log, then copies diagnostics with the link.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                }
                Text(viewModel.diagnosticsState.message)
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(viewModel.diagnosticsState.isError ? OPNDesign.Semantic.destructive : OPNDesign.Text.secondary)
            }
        }
        .settingsSection("diagnostics")
        .disabled(viewModel.isDiagnosticsUploadConfirmationVisible)
    }

    private var diagnosticsButtonTitle: String {
        switch viewModel.diagnosticsState {
        case .ready, .failed: return "GENERATE DIAGNOSTICS"
        case .preparing, .readingLog, .uploading, .copying: return "WORKING"
        case .copied: return "COPIED"
        }
    }
}

struct DiagnosticsUploadConfirmationDialog: View {
    let cancel: () -> Void
    let upload: () -> Void
    let uiScale: CGFloat

    var body: some View {
        ZStack {
            OPNDesign.Surface.scrim
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 18 * uiScale) {
                HStack(alignment: .top, spacing: 14 * uiScale) {
                    ZStack {
                        Rectangle()
                            .fill(OPNDesign.accent.opacity(0.16))
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.settingsFont(size: 18 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.accentInk)
                    }
                    .frame(width: 44 * uiScale, height: 44 * uiScale)
                    .overlay { Rectangle().stroke(OPNDesign.accent.opacity(0.42), lineWidth: 1) }

                    VStack(alignment: .leading, spacing: 7 * uiScale) {
                        Text("Upload diagnostics logs?")
                            .font(.settingsFont(size: 19 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                        Text("OpenNOW will upload the recent sanitized current-run log to paste.c-net.org and copy a diagnostics summary with the public link.")
                            .font(.settingsFont(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10 * uiScale) {
                    Rectangle()
                        .fill(OPNDesign.accent)
                        .frame(width: 4 * uiScale, height: 42 * uiScale)
                    Text("IP addresses and location fields are redacted before upload. Only generate this when preparing support diagnostics.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12 * uiScale)
                .background(OPNDesign.Fill.neutral(0.045))
                .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }

                HStack(spacing: 10 * uiScale) {
                    Spacer(minLength: 0)
                    SettingsDialogButton(title: "CANCEL", tone: .secondary, uiScale: uiScale, action: cancel)
                    SettingsDialogButton(title: "UPLOAD LOGS", tone: .primary, uiScale: uiScale, action: upload)
                }
            }
            .padding(22 * uiScale)
            .frame(width: 430 * uiScale, alignment: .leading)
            .background(OPNDesign.Surface.overlay)
            .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
            .shadow(color: .black.opacity(0.62), radius: 34 * uiScale, x: 0, y: 18 * uiScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsDialogButton: View {
    enum Tone {
        case primary
        case secondary
    }

    let title: String
    let tone: Tone
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(tone == .primary ? OPNDesign.onAccent : OPNDesign.Text.secondary)
                .tracking(0.8)
                .padding(.horizontal, 14 * uiScale)
                .frame(minWidth: 104 * uiScale)
                .frame(height: 34 * uiScale)
                .background(backgroundColor)
                .overlay { Rectangle().stroke(strokeColor, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        switch tone {
        case .primary: return OPNDesign.accent.opacity(isHovering ? 0.88 : 1)
        case .secondary: return isHovering ? OPNDesign.Stroke.subtle : OPNDesign.Fill.neutral(0.06)
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .primary: return OPNDesign.accent
        case .secondary: return OPNDesign.Stroke.regular
        }
    }
}

enum AboutDiagnosticsState: Equatable {
    case ready
    case preparing
    case readingLog
    case uploading
    case copying
    case copied(String)
    case failed(String)

    var message: String {
        switch self {
        case .ready: return "Ready to generate diagnostics. Confirmation is required before logs are uploaded."
        case .preparing: return "Preparing diagnostics metadata..."
        case .readingLog: return "Reading sanitized current-run log..."
        case .uploading: return "Uploading sanitized logs to paste.c-net.org..."
        case .copying: return "Copying diagnostics to clipboard..."
        case .copied(let url): return "Diagnostics copied. Uploaded log: \(url)"
        case .failed(let reason): return "Upload failed, but local diagnostics and inline logs were copied: \(reason)"
        }
    }

    var isWorking: Bool {
        switch self {
        case .preparing, .readingLog, .uploading, .copying: return true
        case .ready, .copied, .failed: return false
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct AboutStatusPill: View {
    let title: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            Text(title.uppercased())
                .font(.settingsFont(size: 9 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
                .tracking(0.8)
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10 * uiScale)
        .frame(height: 28 * uiScale)
        .background(OPNDesign.Stroke.subtle)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
    }
}

struct AboutDetailRow: View {
    @State private var focusIdentity = ControllerFocusIdentity()
    let label: String
    let value: String
    let copyValue: String
    @Binding var copiedKey: String
    var copyDisabled = false
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            Text(label.uppercased())
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
                .tracking(0.5)
                .frame(width: 150 * uiScale, alignment: .leading)
            Text(value.isEmpty ? "Unavailable" : value)
                .font(.settingsFont(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { copy(copyValue) } label: {
                Text(copiedKey == label ? "COPIED" : "COPY")
                    .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(copyDisabled ? OPNDesign.Text.muted : OPNDesign.Text.secondary)
                    .tracking(0.7)
                    .padding(.horizontal, 10 * uiScale)
                    .frame(height: 26 * uiScale)
                    .background(OPNDesign.Fill.neutral(copyDisabled ? 0.03 : 0.06))
                    .overlay { Rectangle().stroke(copyDisabled ? OPNDesign.Fill.neutral(0.05) : OPNDesign.Stroke.regular, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(copyDisabled)
            .controllerFocusable(focusIdentity, activate: { copy(copyValue) })
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty, !copyDisabled else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedKey = label
    }
}
