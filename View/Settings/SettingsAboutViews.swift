import AppKit
import CryptoKit
import SwiftUI

struct AboutSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @State private var copiedKey = ""
    @AppStorage(OpenNOWUpdatePreferences.automaticUpdateChecksEnabledKey) private var automaticUpdateChecksEnabled = OpenNOWUpdatePreferences.defaultAutomaticUpdateChecksEnabled
    @State private var telemetryDisabled = OPNSentry.isTelemetryDisabled()

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Product", uiScale: uiScale) {
                HStack(alignment: .top, spacing: 22 * uiScale) {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.22))
                            .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.72), lineWidth: 1) }
                        VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                            .scaledToFit()
                            .padding(.horizontal, 14 * uiScale)
                    }
                    .frame(width: 180 * uiScale, height: 88 * uiScale)

                    VStack(alignment: .leading, spacing: 12 * uiScale) {
                        HStack(alignment: .firstTextBaseline, spacing: 10 * uiScale) {
                            Text(SettingsAppMetadata.displayName)
                                .font(.settingsNvidia(size: 25 * uiScale, weight: .bold))
                                .foregroundStyle(.white)
                            Text("UNOFFICIAL CLIENT SHELL")
                                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                                .foregroundStyle(.black)
                                .tracking(0.8)
                                .padding(.horizontal, 8 * uiScale)
                                .frame(height: 20 * uiScale)
                                .background(OpenNOWDesign.accent)
                        }
                        Text("A macOS runtime for launching and streaming OpenNOW sessions with local catalog, account, and diagnostics surfaces.")
                            .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8 * uiScale) {
                            AboutStatusPill(title: "Stream", value: viewModel.streamProfile.transportMode.label, uiScale: uiScale)
                            AboutStatusPill(title: "Route", value: route.summary, uiScale: uiScale)
                            AboutStatusPill(title: "Telemetry", value: telemetryDisabled ? "Off" : "On", uiScale: uiScale)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            SettingsCard(title: "Runtime", uiScale: uiScale) {
                AboutDetailRow(label: "Version", value: SettingsAppMetadata.version, copyValue: SettingsAppMetadata.version, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Build", value: SettingsAppMetadata.build, copyValue: SettingsAppMetadata.build, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Bundle", value: bundleIdentifier, copyValue: bundleIdentifier, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "macOS", value: operatingSystemVersion, copyValue: operatingSystemVersion, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Automatic Update Checks", subtitle: automaticUpdateChecksSubtitle, isOn: automaticUpdateChecksEnabled, uiScale: uiScale) { enabled in
                    OpenNOWAppDelegate.setAutomaticApplicationUpdateChecksEnabled(enabled)
                }
                SettingsDivider(uiScale: uiScale)
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: "CHECK FOR UPDATES", uiScale: uiScale) {
                        OpenNOWAppDelegate.requestApplicationUpdateCheck()
                    }
                    Text("Checks GitHub releases and installs a newer signed OpenNOW build when available.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            WhatsNewCard(uiScale: uiScale)

            SettingsCard(title: "Cache", uiScale: uiScale) {
                AboutDetailRow(label: "Catalog Images", value: viewModel.catalogImageCacheSummary, copyValue: viewModel.catalogImageCacheSummary, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: "CLEAR IMAGE CACHE", uiScale: uiScale) {
                        viewModel.clearCatalogImageCache()
                    }
                    Text("Removes cached catalog artwork from disk and memory. Images will download again as needed.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            SettingsCard(title: "Privacy", uiScale: uiScale) {
                SettingsToggleRow(title: "Disable Telemetry", subtitle: "Stops Sentry, trace headers, metrics, and automatic diagnostics logging.", isOn: telemetryDisabled, uiScale: uiScale, action: setTelemetryDisabled)
            }

            SettingsCard(title: "Support Diagnostics", uiScale: uiScale) {
                VStack(alignment: .leading, spacing: 10 * uiScale) {
                    HStack(spacing: 10 * uiScale) {
                        SettingsActionButton(title: diagnosticsButtonTitle, uiScale: uiScale) {
                            viewModel.presentDiagnosticsUploadConfirmation()
                        }
                        .disabled(viewModel.diagnosticsState.isWorking)
                        Text("Uploads the recent sanitized current-run log, then copies diagnostics with the link.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                    Text(viewModel.diagnosticsState.message)
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(viewModel.diagnosticsState.isError ? OpenNOWDesign.Semantic.destructive : .white.opacity(0.62))
                }
            }
        }
            .disabled(viewModel.isDiagnosticsUploadConfirmationVisible)
        }
        .onAppear {
            viewModel.refreshCatalogImageCacheSummary()
            telemetryDisabled = OPNSentry.isTelemetryDisabled()
        }
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: false)
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var operatingSystemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private var automaticUpdateChecksSubtitle: String {
        if OpenNOWUpdatePreferences.updateChecksAreSuspendedForDebugging {
            return "Paused while running a debug build or attached debugger. Manual checks remain available."
        }
        if automaticUpdateChecksEnabled {
            return "Checks GitHub releases on launch and hourly while OpenNOW is running."
        }
        return "OpenNOW will not check for new releases automatically. Manual checks remain available."
    }

    private var diagnosticsButtonTitle: String {
        switch viewModel.diagnosticsState {
        case .ready, .failed: return "GENERATE DIAGNOSTICS"
        case .preparing, .readingLog, .uploading, .copying: return "WORKING"
        case .copied: return "COPIED"
        }
    }

    private func setTelemetryDisabled(_ disabled: Bool) {
        telemetryDisabled = disabled
        OPNSentry.setTelemetryDisabled(disabled)
    }

}

struct DiagnosticsUploadConfirmationDialog: View {
    let cancel: () -> Void
    let upload: () -> Void
    let uiScale: CGFloat

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 18 * uiScale) {
                HStack(alignment: .top, spacing: 14 * uiScale) {
                    ZStack {
                        Rectangle()
                            .fill(OpenNOWDesign.accent.opacity(0.16))
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.settingsNvidia(size: 18 * uiScale, weight: .bold))
                            .foregroundStyle(OpenNOWDesign.accent)
                    }
                    .frame(width: 44 * uiScale, height: 44 * uiScale)
                    .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.42), lineWidth: 1) }

                    VStack(alignment: .leading, spacing: 7 * uiScale) {
                        Text("Upload diagnostics logs?")
                            .font(.settingsNvidia(size: 19 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("OpenNOW will upload the recent sanitized current-run log to paste.c-net.org and copy a diagnostics summary with the public link.")
                            .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10 * uiScale) {
                    Rectangle()
                        .fill(OpenNOWDesign.accent)
                        .frame(width: 4 * uiScale, height: 42 * uiScale)
                    Text("IP addresses and location fields are redacted before upload. Only generate this when preparing support diagnostics.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12 * uiScale)
                .background(Color.white.opacity(0.045))
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }

                HStack(spacing: 10 * uiScale) {
                    Spacer(minLength: 0)
                    SettingsDialogButton(title: "CANCEL", tone: .secondary, uiScale: uiScale, action: cancel)
                    SettingsDialogButton(title: "UPLOAD LOGS", tone: .primary, uiScale: uiScale, action: upload)
                }
            }
            .padding(22 * uiScale)
            .frame(width: 430 * uiScale, alignment: .leading)
            .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1) }
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
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(tone == .primary ? .black : .white.opacity(0.82))
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
        case .primary: return OpenNOWDesign.accent.opacity(isHovering ? 0.88 : 1)
        case .secondary: return Color.white.opacity(isHovering ? 0.10 : 0.06)
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .primary: return OpenNOWDesign.accent
        case .secondary: return Color.white.opacity(0.14)
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
                .font(.settingsNvidia(size: 9 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.8)
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10 * uiScale)
        .frame(height: 28 * uiScale)
        .background(Color.white.opacity(0.065))
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}

struct AboutDetailRow: View {
    let label: String
    let value: String
    let copyValue: String
    @Binding var copiedKey: String
    var copyDisabled = false
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.5)
                .frame(width: 150 * uiScale, alignment: .leading)
            Text(value.isEmpty ? "Unavailable" : value)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { copy(copyValue) } label: {
                Text(copiedKey == label ? "COPIED" : "COPY")
                    .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(copyDisabled ? .white.opacity(0.28) : .white.opacity(0.74))
                    .tracking(0.7)
                    .padding(.horizontal, 10 * uiScale)
                    .frame(height: 26 * uiScale)
                    .background(Color.white.opacity(copyDisabled ? 0.03 : 0.06))
                    .overlay { Rectangle().stroke(Color.white.opacity(copyDisabled ? 0.05 : 0.12), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(copyDisabled)
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
