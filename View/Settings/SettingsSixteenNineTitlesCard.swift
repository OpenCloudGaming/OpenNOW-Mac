import SwiftUI

/// Which games the 16:9 behaviour has learned about, and what was decided for each.
///
/// Detection is silent by design — a title earns the verdict by rendering 16:9 bars for thirty
/// samples of a real session — but "silent" left no way to answer "which of my games does this?".
/// This lists them, shows the answer given at launch, and lets a title be measured again.
struct SettingsSixteenNineTitlesCard: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale
    @State private var titles: [(appId: String, choice: Bool?)] = []

    var body: some View {
        SettingsCard(title: "16:9 Titles", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: 10 * uiScale) {
                Text(titles.isEmpty
                     ? "None yet. A game joins this list after a session where it rendered a 16:9 picture inside a wider stream for about thirty seconds, and you are asked what to do about it the next time you launch it."
                     : "Detected while streaming. Forgetting a title measures it again on its next session and asks you again.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(titles, id: \.appId) { entry in
                    SettingsDivider(uiScale: uiScale)
                    HStack(spacing: 12 * uiScale) {
                        VStack(alignment: .leading, spacing: 3 * uiScale) {
                            Text(displayName(for: entry.appId))
                                .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                            Text(choiceDescription(entry.choice))
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 8)
                        SettingsActionButton(title: "FORGET", minimumWidth: 104 * uiScale, uiScale: uiScale) {
                            OPNStreamPreferences.forgetSixteenNineTitle(entry.appId)
                            reload()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        titles = OPNStreamPreferences.knownSixteenNineTitles()
    }

    private func choiceDescription(_ choice: Bool?) -> String {
        switch choice {
        case .some(true): "Streaming at 16:9"
        case .some(false): "Keeping your resolution"
        case .none: "You will be asked on the next launch"
        }
    }

    /// The catalog name when this Mac has the game loaded, the app id when it does not: the list is
    /// keyed by id, and a session can have flagged a title that is not in the current catalog page.
    private func displayName(for appId: String) -> String {
        let match = (viewModel.libraryGames + viewModel.catalogGames).first {
            $0.launchAppId == appId || $0.id == appId
        }
        guard let title = match?.title, !title.isEmpty else { return "App \(appId)" }
        return title
    }
}
