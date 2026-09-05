//  The scrolling half of the detail panel: description, NVIDIA tech, content rating and the
//  read-more control.
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

extension GameDetailPanel {
    /// Collapsed the panel shows the summary and nothing else, truncated by whole lines. It used to
    /// show every block clipped to a fixed height, which sliced the rating badge and the detail rows
    /// through the middle — a hard cut mid-element reads as a rendering bug, not as "there is more".
    func detailMetadataScrollArea(game: OPNCatalogGameObject, panelHeight: CGFloat) -> some View {
        // Text area grows with the panel so tall (ultrawide) panels do not leave a dead gap.
        let collapsedHeight = OpenNOWDesign.clamped(panelHeight * 0.256, minimum: 128, maximum: 210)
        let expandedHeight = OpenNOWDesign.clamped(panelHeight * 0.496, minimum: 248, maximum: 420)
        let collapsedLineLimit = max(3, Int(collapsedHeight / 22))
        return Group {
            if isDescriptionExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        shortDescription(game: game)
                        divider
                        nvidiaTechRows(game: game)
                        ratingBlock(game: game)
                        detailRows(game: game)
                        fullDescription(game: game)
                    }
                    .frame(maxWidth: 660, alignment: .leading)
                    .padding(.trailing, 8)
                }
                .frame(maxWidth: 660, maxHeight: expandedHeight, alignment: .topLeading)
            } else {
                // No reserved height: a `maxHeight` frame here takes the whole proposal and pushes
                // the read-more control a paragraph away from the text it belongs to.
                shortDescription(game: game)
                    .lineLimit(collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func shortDescription(game: OPNCatalogGameObject) -> some View {
        Text(GameDetailPresentation.shortDescription(game: game))
            .nvidiaFont(size: 15, weight: .medium)
            .foregroundStyle(.white.opacity(0.90))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 660, alignment: .leading)
    }

    func fullDescription(game: OPNCatalogGameObject) -> some View {
        let description = GameDetailPresentation.longDescription(game: game)
        return VStack(alignment: .leading, spacing: 8) {
            if !description.isEmpty {
                Text("FULL DESCRIPTION")
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.56))
                Text(description)
                    .nvidiaFont(size: 14, weight: .medium)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.24))
            .frame(height: 1)
    }

    func nvidiaTechRows(game: OPNCatalogGameObject) -> some View {
        let technologies = GameDetailPresentation.supportedTechnologyLabels(game: game)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(technologies.prefix(2), id: \.self) { technology in
                CatalogFeatureAvailabilityRow(title: technology, message: GameDetailPresentation.featureMessage(technology), locked: GameDetailPresentation.featureIsLocked(technology))
            }
        }
        .padding(.vertical, technologies.isEmpty ? 0 : 2)
        .frame(maxWidth: 660, alignment: .leading)
    }

    func ratingBlock(game: OPNCatalogGameObject) -> some View {
        HStack(alignment: .top, spacing: 18) {
            if !game.ratingLabel.isEmpty {
                CatalogRatingBadge(game: game, shortRating: GameDetailPresentation.esrbShortRating(game.ratingLabel))
            }
            let descriptors = GameDetailPresentation.ratingDescriptors(game: game)
            VStack(alignment: .leading, spacing: 0) {
                Text(game.ratingLabel.isEmpty ? "CLOUD GAMING" : game.ratingLabel.uppercased())
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.bottom, 7)
                ForEach(Array(descriptors.enumerated()), id: \.element) { index, descriptor in
                    Text(descriptor)
                        .nvidiaFont(size: 12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(maxWidth: 215, alignment: .leading)
                        .padding(.bottom, 5)
                    if index < descriptors.count - 1 {
                        divider
                            .frame(maxWidth: 215)
                            .padding(.bottom, 5)
                    }
                }
            }
        }
    }

    var readMoreButton: some View {
        Button {
            isDescriptionExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(isDescriptionExpanded ? "READ LESS" : "READ MORE")
                Image(systemName: isDescriptionExpanded ? "chevron.up" : "chevron.down")
            }
            .nvidiaFont(size: 13, weight: .bold)
            .foregroundStyle(.white.opacity(0.95))
        }
        .buttonStyle(.plain)
    }
}
