//  The reading half of the detail panel: the summary paragraph and the control that opens the full
//  game info page.
//

import SwiftUI

extension GameDetailPanel {
    /// The panel prints the summary only, truncated by whole lines. It used to expand in place to
    /// every metadata block clipped to a fixed height, which sliced the rating badge and the detail
    /// rows through the middle - a hard cut mid-element reads as a rendering bug, not as "there is
    /// more". The long copy, the screenshots, the technology rows and the spec table now live on
    /// the full info page instead.
    func detailMetadataScrollArea(game: OPNCatalogGameObject, panelHeight: CGFloat) -> some View {
        // Line budget grows with the panel so tall (ultrawide) panels do not leave a dead gap. No
        // reserved height: a `maxHeight` frame here takes the whole proposal and pushes the button
        // a paragraph away from the text it belongs to.
        let collapsedHeight = OpenNOWDesign.clamped(panelHeight * 0.256, minimum: 128, maximum: 210)
        return shortDescription(game: game)
            .lineLimit(max(3, Int(collapsedHeight / 22)))
            .fixedSize(horizontal: false, vertical: true)
    }

    func shortDescription(game: OPNCatalogGameObject) -> some View {
        Text(GameDetailPresentation.shortDescription(game: game))
            .catalogFont(size: 15, weight: .medium)
            .foregroundStyle(.white.opacity(0.90))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 660, alignment: .leading)
    }

    /// Opens the full info page. It reads as a control, not as a caption: the panel truncates the
    /// description, so this is the only route to the rest of it.
    var moreInfoButton: some View {
        Button { viewModel.showGameInfo() } label: {
            HStack(spacing: 7) {
                Text("READ MORE")
                    .catalogFont(size: 12, weight: .bold)
                    .tracking(0.8)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .catalogFont(size: 11, weight: .bold)
            }
            .foregroundStyle(isMoreInfoHovering ? .black.opacity(0.88) : OpenNOWDesign.Text.primary)
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 34 * uiScale)
            .background(isMoreInfoHovering ? OpenNOWDesign.accent : Color.white.opacity(0.10))
            .overlay { Rectangle().stroke(isMoreInfoHovering ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.strong, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isMoreInfoHovering = $0 }
        .accessibilityLabel("Read more about this game")
    }
}
