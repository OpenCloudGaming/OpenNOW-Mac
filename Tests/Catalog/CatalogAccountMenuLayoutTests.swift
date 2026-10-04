//  The account menu's rows are drawn into a fixed 260pt panel, so a label that does not fit is
//  clipped rather than wrapped. These check the labels against the width the row actually leaves,
//  and render the panel at every interface scale so it can be looked at without launching the app.

import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@Suite struct CatalogAccountMenuLayoutTests {
    private static let scales: [CGFloat] = [1, 1.25, 1.5]

    /// A label the menu draws, at the size the row draws it. The two are kept together so a change to
    /// either cannot silently invalidate the measurement.
    private struct RowLabel {
        let text: String
        let size: CGFloat
        let weight: OPNUIFont.Weight
    }

    private static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("View/Catalog/CatalogAccountMenuViews.swift")
    }

    /// Every literal label an account-menu row draws, read out of the source so a new row is covered.
    private static func renderedRowLabels() throws -> [RowLabel] {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        func literals(matching pattern: String) throws -> [String] {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            return expression.matches(in: source, range: range).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            }
        }
        let titles = try literals(matching: #"CatalogAccountDropdownRow\(\s*(?:\n\s*)?title:\s*"([^"]+)""#)
        // Every `subtitle:` literal in this file belongs to an account-menu row; the scan cannot
        // anchor on the call because the subtitle follows the title argument.
        let subtitles = try literals(matching: #"(?<![\w])subtitle:\s*"([^"]+)""#)
        return titles.map { RowLabel(text: $0, size: 14, weight: .bold) }
            + subtitles.map { RowLabel(text: $0, size: 11, weight: .medium) }
    }

    @MainActor
    @Test func everyAccountMenuLabelFitsTheMenu() throws {
        let labels = try Self.renderedRowLabels()
        #expect(labels.count >= 5, "the source scan found \(labels.count) labels; the row pattern has drifted")

        for scale in Self.scales {
            let budget = CatalogAccountDropdownRow.titleWidth(
                inMenuWidth: CatalogVendorLayout.accountMenuWidth(scale: scale),
                scale: scale
            )
            for label in labels {
                let measured = (label.text as NSString)
                    .size(withAttributes: [.font: OPNUIFont.nsFont(size: label.size * scale, weight: label.weight)])
                    .width
                #expect(measured <= budget, "“\(label.text)” needs \(measured)pt of the \(budget)pt a row leaves it at Interface Scale \(scale)")
            }
        }
    }

    /// Renders the open panel at every interface scale, so the labels can be read rather than
    /// measured. Written only when `OPN_SNAPSHOT_DIR` names a directory.
    @MainActor
    @Test func theAccountMenuRendersAtEveryInterfaceScale() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let model = makeCatalogViewModelForTesting()
        for scale in Self.scales {
            let panel = CatalogAccountDropdownPanel(
                viewModel: model,
                accounts: [model.account],
                signedOutAccountEmails: [],
                isPresented: .constant(true),
                onSwitch: { _ in },
                onAddAccount: {},
                onSignOut: { _ in },
                onForget: { _ in }
            )
            .environment(\.opnUIScale, scale)

            let renderer = ImageRenderer(content: panel)
            renderer.scale = 1
            let image = try #require(renderer.nsImage, "the account menu did not render at Interface Scale \(scale)")
            writeSnapshot(image, name: "account-menu-scale-\(scale).png")
            #expect(image.size.width > 0)
        }
    }

    @MainActor
    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
