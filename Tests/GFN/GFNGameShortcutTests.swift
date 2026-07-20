import Foundation
import Foundation
import Testing
@testable import MacForceNow

@Test func gameShortcutRoundTripsLaunchRouteIdentifiers() throws {
    let shortcut = GFNGameShortcut(
        sourceURL: nil,
        displayName: "Portal on GeForce NOW",
        cmsId: "123456",
        shortName: "portal",
        parentGameId: "portal-parent"
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("Portal on GeForce NOW.gfnpc")
    try shortcut.write(to: url)

    let parsed = try GFNGameShortcut(fileURL: url)
    #expect(parsed.cmsId == "123456")
    #expect(parsed.shortName == "portal")
    #expect(parsed.parentGameId == "portal-parent")
    #expect(parsed.lookupTitle == "Portal")
}

@Test func gameShortcutAcceptsCmsIdOnlyPayloadForDirectLaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("Direct Launch on GeForce NOW.gfnpc")
    let data = try JSONSerialization.data(withJSONObject: ["url-route": "#?cmsId=987654&launchSource=External"], options: [])
    try data.write(to: url, options: .atomic)

    let parsed = try GFNGameShortcut(fileURL: url)
    #expect(parsed.cmsId == "987654")
    #expect(parsed.shortName.isEmpty)
    #expect(parsed.parentGameId.isEmpty)
    #expect(parsed.lookupTitle == "Direct Launch")
}

@Test func gfnpcDocumentTypeDeclaresShortcutIcon() throws {
    let rootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistURL = rootURL.appendingPathComponent("MacForceNow-Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    let documentTypes = try #require(plist?["CFBundleDocumentTypes"] as? [[String: Any]])
    let gfnpcType = try #require(documentTypes.first { type in
        let extensions = type["CFBundleTypeExtensions"] as? [String] ?? []
        return extensions.contains("gfnpc")
    })

    #expect(gfnpcType["CFBundleTypeIconFile"] as? String == "AppIcon")
}
