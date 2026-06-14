import Backend
import SwiftUI

@MainActor
private final class OPNEmailEntryModel: ObservableObject {
    struct Provider: Identifiable, Equatable {
        let id: String
        let label: String
    }

    @Published var providers: [Provider]
    @Published var selectedProviderId: String
    @Published var stayLoggedIn: Bool

    init() {
        let providerId = OPNAuthService.defaultIdpId
        providers = [Provider(id: providerId, label: "NVIDIA")]
        selectedProviderId = providerId
        stayLoggedIn = OPNAuthServiceDirect.shared.getStayLoggedIn()
    }

    func setProviderItems(ids: [String], labels: [String], selectedId: String) {
        var nextProviders: [Provider] = []
        for index in ids.indices {
            let id = ids[index]
            guard !id.isEmpty else { continue }
            let label = index < labels.count && !labels[index].isEmpty ? labels[index] : "NVIDIA"
            nextProviders.append(Provider(id: id, label: label))
        }
        if nextProviders.isEmpty {
            nextProviders = [Provider(id: OPNAuthService.defaultIdpId, label: "NVIDIA")]
        }
        providers = nextProviders
        selectedProviderId = nextProviders.contains { $0.id == selectedId } ? selectedId : nextProviders[0].id
    }
}

@objc(OPNEmailEntryView)
@MainActor
final class OPNEmailEntryView: NSView {
    @objc var onSignInWithBrowser: (() -> Void)?
    @objc var stayLoggedInToggle = NSButton(frame: .zero)

    private let model = OPNEmailEntryModel()
    private var hostingView: NSHostingView<OPNEmailEntrySwiftUIView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    @objc(setProviderItemsWithIds:labels:selectedId:)
    func setProviderItems(ids: [String], labels: [String], selectedId: String) {
        model.setProviderItems(ids: ids, labels: labels, selectedId: selectedId)
    }

    @objc(setLoginProviders:selectedProviderIdpId:)
    func setLoginProviders(_ providers: NSArray, selectedProviderIdpId selectedId: NSString) {
        var ids: [String] = []
        var labels: [String] = []
        for provider in providers {
            let object = provider as AnyObject
            let id = (object.value(forKey: "idpId") as? String) ?? (object.value(forKey: "id") as? String) ?? ""
            guard !id.isEmpty else { continue }
            let code = ((object.value(forKey: "providerCode") as? String) ?? (object.value(forKey: "code") as? String) ?? "").uppercased()
            let name = (object.value(forKey: "providerName") as? String) ?? (object.value(forKey: "name") as? String) ?? ""
            ids.append(id)
            labels.append(code == "BPC" ? "bro.game" : (name.isEmpty ? "NVIDIA" : name))
        }
        setProviderItems(ids: ids, labels: labels, selectedId: selectedId as String)
    }

    @objc func selectedProviderIdentifier() -> String {
        let selected = model.selectedProviderId
        return selected.isEmpty ? OPNAuthService.defaultIdpId : selected
    }

    @objc(selectedProviderIdpId)
    func selectedProviderIdpId() -> String {
        selectedProviderIdentifier()
    }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        stayLoggedInToggle.state = model.stayLoggedIn ? .on : .off
        let root = OPNEmailEntrySwiftUIView(model: model) { [weak self] in
            guard let self else { return }
            stayLoggedInToggle.state = model.stayLoggedIn ? .on : .off
            OPNAuthServiceDirect.shared.setStayLoggedIn(model.stayLoggedIn)
            onSignInWithBrowser?()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNEmailEntrySwiftUIView: View {
    @ObservedObject var model: OPNEmailEntryModel
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: OPNUIHelpers.color(rgb: 0x191919, alpha: 1.0))
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.50), .black.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text("GEFORCE NOW")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: 1.0)))
                    .tracking(1.4)

                Text("Sign In")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.top, 12)

                Text("Access your cloud gaming library with your NVIDIA account.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                Rectangle()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 1)
                    .padding(.top, 26)

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign-in provider")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.62))
                        Picker("Sign-in provider", selection: $model.selectedProviderId) {
                            ForEach(model.providers) { provider in
                                Text(provider.label).tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Toggle("Keep me signed in", isOn: $model.stayLoggedIn)
                        .toggleStyle(.switch)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .tint(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: 1.0)))

                    Button(action: onContinue) {
                        Text("Continue with Browser")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(OPNEmailEntryActionButtonStyle())
                }
                .padding(.top, 26)

                Spacer(minLength: 0)

                Text("OpenNOW for macOS")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 42)
            .frame(width: 456, height: 438, alignment: .topLeading)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x292929, alpha: 0.96)))
            .overlay(Rectangle().stroke(Color.white.opacity(0.20), lineWidth: 1))
            .shadow(color: .black.opacity(0.48), radius: 28, y: 16)
        }
    }
}

private struct OPNEmailEntryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: configuration.isPressed ? 0.78 : 1.0)))
            .overlay(Rectangle().stroke(Color(nsColor: OPNUIHelpers.color(rgb: 0x8FD127, alpha: 0.75)), lineWidth: 1))
    }
}
