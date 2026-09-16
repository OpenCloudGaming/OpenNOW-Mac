import Foundation
import Testing
@testable import OpenNOW

@MainActor
@Suite("Controller tools")
struct ControllerToolsTests {
    @Test func mappingSearchTargetsSharedControllerTools() throws {
        let entry = try #require(SettingsSearchIndex.results(for: "Controller Mapping").first)
        #expect(entry.title == "Controller Mapping")
        #expect(entry.group == .input)
        #expect(entry.sectionID == "controller-tools")
    }

    @Test func dualShockShellFillMatchesItsContour() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("View/Assets.xcassets")
        let outline = try XMLDocument(contentsOf: assets.appendingPathComponent("DualShockControllerShell.imageset/shell.svg"))
        let fill = try XMLDocument(contentsOf: assets.appendingPathComponent("DualShockControllerShellFill.imageset/shell-fill.svg"))
        let outlinePaths = try outline.nodes(forXPath: "//*[local-name()='path']/@d").compactMap(\.stringValue)
        let fillPaths = try fill.nodes(forXPath: "//*[local-name()='path']/@d").compactMap(\.stringValue)
        let contour = try #require(outlinePaths.max(by: { $0.count < $1.count }))
        #expect(fillPaths.contains(contour))
        #expect(outline.rootElement()?.attribute(forName: "viewBox")?.stringValue == "0 0 456 320")
        #expect(fill.rootElement()?.attribute(forName: "viewBox")?.stringValue == "0 0 456 320")
    }
}
