import Foundation
import Testing
@testable import OpenNOW

/// Search is only worth having if every result leads somewhere real and no setting is missing from
/// it. Both halves are checked against the source, not against a second hand-written list.
@Suite struct SettingsSearchTests {
    /// Files whose rows are deliberately absent from the index. A wizard step exists only inside a
    /// modal, so a result naming it would scroll to a card that is not on the page.
    private static let unindexedFiles: Set<String> = [
        "SettingsRemoteCoOpSetupWizard.swift",
        "SettingsRemoteCoOpSetupWizardSteps.swift",
        "SettingsRemoteCoOpRelayWizard.swift",
        "SettingsRemoteCoOpRelayCard.swift",
    ]

    /// Rows that render only once another setting is on, so they are searchable through the control
    /// that gates them rather than by their own name. A result naming one directly would scroll to a
    /// card that does not contain it.
    private static let gatedByAnotherSetting: Set<String> = [
        "Protocol", "Host", "Port", "Username", "Password", "Scope",
        "Edge Dimming",
    ]

    private static var settingsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("View/Settings", isDirectory: true)
    }

    /// Every row title rendered by a scrollable settings page, read out of the source.
    private static func renderedRowTitles() throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(at: settingsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !unindexedFiles.contains($0.lastPathComponent) }
        let pattern = try NSRegularExpression(
            pattern: #"Settings(?:Toggle|Option|Menu|Slider|TextField|SecureTextField|Color)Row\(\s*(?:\n\s*)?title:\s*"([^"]+)""#
        )
        var titles: [String: String] = [:]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let titleRange = Range(match.range(at: 1), in: source) else { continue }
                titles[String(source[titleRange])] = file.lastPathComponent
            }
        }
        return titles
    }

    @MainActor @Test func everyResultLeadsToACardThatExists() {
        for entry in SettingsSearchIndex.entries {
            guard let sectionID = entry.sectionID else {
                // Only a destination with no section map may omit one.
                #expect(SettingsSearchIndex.sections(for: entry.group).isEmpty, "\(entry.title) omits a section on a destination that has them")
                continue
            }
            let ids = SettingsSearchIndex.sections(for: entry.group).map(\.id)
            #expect(ids.contains(sectionID), "\(entry.title) points at \(entry.group.rawValue)/\(sectionID), which is not a section there")
        }
    }

    @Test func theIndexNamesEachSettingOnce() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "the index repeats an entry")
        for entry in SettingsSearchIndex.entries {
            #expect(!entry.title.isEmpty)
        }
    }

    @MainActor @Test func everyRowOnAScrollablePageIsSearchable() throws {
        let rendered = try Self.renderedRowTitles()
        #expect(rendered.count > 40, "the source scan found almost nothing; the row pattern has drifted")
        let indexed = Set(SettingsSearchIndex.entries.map(\.title))
        let missing = rendered.filter { !indexed.contains($0.key) && !Self.gatedByAnotherSetting.contains($0.key) }
        #expect(missing.isEmpty, "not searchable: \(missing.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", "))")
    }

    @MainActor @Test func everyIndexedSettingStillExists() throws {
        let rendered = Set(try Self.renderedRowTitles().keys)
        // The microphone test is its own component rather than a generic row, so the scan cannot see
        // it; everything else in the index must still be rendered somewhere.
        let unscannable: Set<String> = ["Microphone Test", "Cloudmatch Region"]
        let stale = SettingsSearchIndex.entries
            .map(\.title)
            .filter { !rendered.contains($0) && !unscannable.contains($0) }
        #expect(stale.isEmpty, "indexed but no longer rendered: \(stale.sorted().joined(separator: ", "))")
    }

    /// A gated row is still findable, through whatever switches it on.
    @MainActor @Test func aGatedSettingIsFoundThroughTheControlThatGatesIt() {
        #expect(SettingsSearchIndex.results(for: "socks").contains { $0.title == "Session Proxy" })
        #expect(SettingsSearchIndex.results(for: "password").contains { $0.title == "Session Proxy" })
        #expect(SettingsSearchIndex.results(for: "edge dimming").contains { $0.title == "Pillarbox Fill" })
        // And no result names a row that would not be on screen when the reader arrives.
        let indexed = Set(SettingsSearchIndex.entries.map(\.title))
        #expect(indexed.isDisjoint(with: Self.gatedByAnotherSetting))
    }

    @MainActor @Test func aQueryFindsSettingsByLabelAndByTheWordTheReaderKnows() {
        #expect(SettingsSearchIndex.results(for: "surround").contains { $0.title == "Surround Sound" })
        // The reader's word, not the label.
        #expect(SettingsSearchIndex.results(for: "5.1").contains { $0.title == "Surround Sound" })
        #expect(SettingsSearchIndex.results(for: "black bars").contains { $0.title == "Pillarbox Fill" })
        #expect(SettingsSearchIndex.results(for: "vsync").contains { $0.title == "Cloud G-Sync" })
        #expect(SettingsSearchIndex.results(for: "notification").contains { $0.title == "When the Stream Is Ready" })
        // Case and diacritics do not matter.
        #expect(SettingsSearchIndex.results(for: "hdr").contains { $0.title == "HDR" })
        #expect(SettingsSearchIndex.results(for: "cödec").contains { $0.title == "Codec" })
    }

    @MainActor @Test func aLabelMatchOutranksAMentionOfTheSameWord() {
        let results = SettingsSearchIndex.results(for: "bitrate")
        #expect(results.first?.title.localizedCaseInsensitiveContains("bitrate") == true, "a row named for the query must come first")
    }

    @MainActor @Test func oneCharacterIsNotAQuery() {
        #expect(SettingsSearchIndex.results(for: "").isEmpty)
        #expect(SettingsSearchIndex.results(for: "h").isEmpty)
        #expect(SettingsSearchIndex.results(for: "  ").isEmpty)
        #expect(!SettingsSearchIndex.results(for: "hd").isEmpty)
    }

    @MainActor @Test func aResultSaysWhereItLives() throws {
        let surround = try #require(SettingsSearchIndex.entries.first { $0.title == "Surround Sound" })
        #expect(SettingsSearchIndex.location(of: surround) == "Audio › Output")
        let coOp = try #require(SettingsSearchIndex.entries.first { $0.group == .remoteCoOp })
        // No section map, so the destination alone is as precise as it gets.
        #expect(SettingsSearchIndex.location(of: coOp) == "Remote Co-Op")
    }
}
