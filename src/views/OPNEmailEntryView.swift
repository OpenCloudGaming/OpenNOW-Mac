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
            Color.clear
            VStack(spacing: 18) {
                Text("OpenNOW")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 22) {
                    Text("Access your cloud gaming library with your NVIDIA account.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign-in provider")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
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
                        .font(.system(size: 13, weight: .medium))

                    Button(action: onContinue) {
                        Text("Continue with Browser")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.204, green: 0.780, blue: 0.349))
                }
                .padding(.horizontal, 56)
                .padding(.vertical, 46)
                .frame(width: 400, height: 372)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.26), radius: 24, y: 14)

                Text("Open-source cloud gaming client for macOS")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 480, height: 500)
        }
    }
}
