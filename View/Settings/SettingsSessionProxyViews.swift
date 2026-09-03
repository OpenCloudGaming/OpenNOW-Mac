import SwiftUI

struct SessionProxySettingsPage: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale
    @State private var settings = OPNSessionProxySettings()
    @State private var password = ""
    @State private var savedSettings = OPNSessionProxySettings()
    @State private var savedPassword = ""
    @State private var isTesting = false
    @State private var testMessage = ""
    @State private var testSucceeded = false

    var body: some View {
        SettingsCard(title: "Session Proxy", uiScale: uiScale) {
            SettingsToggleRow(
                title: "Session Proxy",
                subtitle: "Route GeForce NOW catalog, session creation, and queue requests through a proxy. Streaming and signaling traffic always connects directly.",
                isOn: settings.isEnabled,
                uiScale: uiScale
            ) { newValue in
                settings.isEnabled = newValue
            }
            if settings.isEnabled {
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(
                    title: "Protocol",
                    subtitle: "Proxy server protocol. SOCKS5 also accepts unauthenticated SOCKS4 servers.",
                    options: OPNSessionProxyScheme.allCases.map(\.title),
                    selectedIndex: OPNSessionProxyScheme.allCases.firstIndex(of: settings.scheme) ?? 0,
                    uiScale: uiScale
                ) { index in
                    settings.scheme = OPNSessionProxyScheme.allCases[index]
                }
                SettingsDivider(uiScale: uiScale)
                SettingsTextFieldRow(
                    title: "Host",
                    subtitle: "Proxy server hostname or IP address.",
                    text: settings.host,
                    placeholder: "proxy.example.com",
                    uiScale: uiScale
                ) { newValue in
                    settings.host = newValue
                }
                SettingsDivider(uiScale: uiScale)
                SettingsTextFieldRow(
                    title: "Port",
                    subtitle: "Proxy server port (1-65535).",
                    text: settings.port,
                    placeholder: "3128",
                    uiScale: uiScale
                ) { newValue in
                    settings.port = newValue.filter { $0.isNumber }
                }
                SettingsDivider(uiScale: uiScale)
                SettingsTextFieldRow(
                    title: "Username",
                    subtitle: "Optional. Required when a password is set.",
                    text: settings.username,
                    placeholder: "Optional",
                    uiScale: uiScale
                ) { newValue in
                    settings.username = newValue
                }
                SettingsDivider(uiScale: uiScale)
                SettingsSecureTextFieldRow(
                    title: "Password",
                    subtitle: "Optional. Saved with the app's preferences on this Mac.",
                    text: $password,
                    placeholder: "Optional",
                    uiScale: uiScale
                ) { newValue in
                    password = newValue
                }
                if settings.isEnabled && !isConfigurationValid {
                    SettingsDivider(uiScale: uiScale)
                    SettingsMessageView(
                        message: "Enter a valid host and port to activate the proxy. Requests connect directly until then.",
                        systemImage: "exclamationmark.triangle.fill",
                        uiScale: uiScale
                    )
                }
            }
            if settings.isEnabled {
                SettingsDivider(uiScale: uiScale)
                HStack(spacing: 12 * uiScale) {
                    if !testMessage.isEmpty {
                        Text(testMessage)
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(testSucceeded ? OpenNOWDesign.accent : Color.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    SettingsActionButton(title: isTesting ? "TESTING" : "TEST", minimumWidth: 104 * uiScale, uiScale: uiScale) {
                        testConnection()
                    }
                    .disabled(!isConfigurationValid || isTesting)
                    if isDirty {
                        SettingsActionButton(title: "SAVE", minimumWidth: 104 * uiScale, uiScale: uiScale) {
                            save()
                        }
                        .disabled(!isConfigurationValid)
                    }
                }
            }
        }
        .onAppear(perform: restoreSaved)
    }

    private var isConfigurationValid: Bool {
        OPNSessionProxyStore.configuration(from: settings, password: password) != nil
    }

    private var isDirty: Bool {
        settings != savedSettings || password != savedPassword
    }

    private func restoreSaved() {
        savedSettings = OPNSessionProxyStore.load()
        savedPassword = OPNSessionProxyStore.loadPassword()
        settings = savedSettings
        password = savedPassword
    }

    private func testConnection() {
        guard let configuration = OPNSessionProxyStore.configuration(from: settings, password: password) else { return }
        isTesting = true
        testMessage = ""
        Task { @MainActor in
            let result = await OPNSessionProxySessionProvider.shared.testConnection(configuration: configuration)
            isTesting = false
            switch result {
            case .success(let latencyMs):
                testSucceeded = true
                testMessage = "Proxy reachable through \(configuration.endpointDescription) in \(latencyMs) ms."
            case .failure(let error):
                testSucceeded = false
                testMessage = "Proxy test failed: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        let previousRouteKey = OPNSessionProxyStore.configuration()?.cacheKey ?? "direct"
        OPNSessionProxyStore.save(settings)
        OPNSessionProxyStore.savePassword(password)
        savedSettings = settings
        savedPassword = password
        let newRouteKey = OPNSessionProxyStore.configuration()?.cacheKey ?? "direct"
        guard newRouteKey != previousRouteKey else { return }
        viewModel.refresh()
    }
}
