import Foundation
import Testing
@testable import OpenNOW

/// The dock scrolls the row the pad's ring stands on into view. `proxy.scrollTo` reaches a row by
/// identity, so every row the pad can walk has to be stamped with the id the model resolves its focus
/// to — a row with no stamp is a row the ring leaves the visible area for, which is the bug this
/// guards. The stamps live in the views, so they are read out of the source the way the Settings
/// search index is checked against the rows its pages draw.
@MainActor
struct StreamHUDScrollAnchorTests {
    private func entry(_ id: String, group: String = "", columns: Int = 1, kind: StreamHUDFocusEntryKind = .control) -> StreamHUDFocusEntry {
        StreamHUDFocusEntry(id: id, isDisabled: false, group: group, columns: columns, kind: kind, action: {})
    }

    // MARK: - Resolving the pad's focus to a row

    @Test func theAnchorIsTheRowThePadWalks() {
        let entries = [
            entry("mic", group: "audio", columns: 2), entry("volume", group: "audio", columns: 2),
            entry("sensitivity"),
            entry("tier"), entry("clarity"),
        ]
        // Left/right moves inside a row, so the row's first entry is what the dock scrolls to.
        #expect(StreamHUDFocusEntry.scrollAnchor(for: "mic", in: entries) == "mic")
        #expect(StreamHUDFocusEntry.scrollAnchor(for: "volume", in: entries) == "mic")
        // A full-width row anchors on itself.
        #expect(StreamHUDFocusEntry.scrollAnchor(for: "clarity", in: entries) == "clarity")
    }

    /// A section header is a row of its own, so a folded section the pad stands on stays on screen.
    @Test func aSectionHeaderAnchorsOnItself() {
        let sections: [StreamHUDFocusEntry.Section] = [
            .init(section: .audio, action: {}, content: [entry("mic", group: "audio", columns: 2)]),
            .init(section: .capture, action: {}, content: [entry("rec", group: "capture", columns: 4)]),
        ]
        let entries = StreamHUDFocusEntry.sectioned(sections, collapsed: [.audio])
        #expect(StreamHUDFocusEntry.scrollAnchor(for: OPNStreamHUDSection.audio.focusID, in: entries) == OPNStreamHUDSection.audio.focusID)
        #expect(StreamHUDFocusEntry.scrollAnchor(for: "rec", in: entries) == "rec")
    }

    /// The power button is the dock's header action, outside the list the pad scrolls: nothing is
    /// scrolled for it, so the dock cannot jump when the pad reaches the top of the ring.
    @Test func aDockWideActionHasNoRowToScrollTo() {
        let entries = [entry("quit-menu", kind: .globalAction), entry("mic", group: "audio", columns: 2)]
        #expect(StreamHUDFocusEntry.scrollAnchor(for: "quit-menu", in: entries) == nil)
        #expect(StreamHUDFocusEntry.scrollAnchor(for: "gone", in: entries) == nil)
    }

    /// The HUD seeds a focus cursor when it opens but draws no ring until the pad moves, so the dock
    /// opens at its top rather than scrolled to a cursor nobody can see.
    @Test func theDockScrollsTheRowThePadStandsOnOnceTheRingIsVisible() {
        let (_, model) = makeHUDSurface()
        #expect(model.hudScrollAnchorID == nil)

        model.hudFocusID = NativeNVSTHostViewModel.gameVolumeFocusID
        #expect(model.hudScrollAnchorID == nil, "the seeded cursor does not scroll the dock on its own")

        model.isHUDGamepadFocusVisible = true
        #expect(model.hudScrollAnchorID == NativeNVSTHostViewModel.gameVolumeMuteFocusID, "the slider shares the row its icon anchors")
    }

    // MARK: - The stamps the dock draws

    /// Every row of the pad's walk is stamped, either by name or through the one helper that draws
    /// it, and no stamp names a row that does not exist. The rows come from the model's own layout,
    /// which is what the pad walks, so a panel row added without an anchor fails here rather than
    /// silently scrolling nowhere.
    @Test func everyRowThePadCanWalkIsAnchored() throws {
        var expected: Set<String> = []
        var shared: [(expression: String, anchors: Set<String>)] = []
        withPreservedHUDSettings {
            let wasClipboardCaptureEnabled = OPNLabs.isClipboardCaptureEnabled
            OPNLabs.setEnabled(OPNLabs.clipboardCapture, true)
            defer { OPNLabs.setEnabled(OPNLabs.clipboardCapture, wasClipboardCaptureEnabled) }

            let (_, model) = makeHUDSurface()
            model.controllerBatteries = [ControllerBatteryInfo(id: "pad", label: "P1", level: 80, charging: false)]
            model.clipboard.entries = [StreamClipboardEntry(text: "captured text", applicationID: "100", gameTitle: "Game")]
            model.remoteCoOpPreferences.isEnabled = true
            model.remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(
                preferences: model.remoteCoOpPreferences,
                invite: nil,
                participants: [
                    OPNRemoteCoOpParticipant(displayName: "Guest", role: .guest, connectionState: .connected),
                    OPNRemoteCoOpParticipant(displayName: "Waiting", role: .guest, connectionState: .waitingForApproval),
                ]
            )

            let entries = model.hudFocusEntries
            expected = Set(entries.compactMap { StreamHUDFocusEntry.scrollAnchor(for: $0.id, in: entries) })
            shared = Self.sharedRowAnchors(entries)
        }

        let stamped = try Self.stampedAnchors()
        #expect(stamped.count > 10, "the source scan found almost nothing; the anchor pattern has drifted")
        let resolved = try Self.resolvedAnchors(stamped, sharedExpressions: Set(shared.map(\.expression)))
        let covered = Set(resolved)

        #expect(covered.isSubset(of: expected), "anchored but not a row the pad walks: \(covered.subtracting(expected).sorted())")
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for value in resolved where !seen.insert(value).inserted { repeated.insert(value) }
        #expect(repeated.isEmpty, "a row is anchored twice: \(repeated.sorted())")

        for anchor in expected.subtracting(covered).sorted() {
            let covering = shared.first { $0.anchors.contains(anchor) }
            #expect(covering != nil, "\(anchor) is a row the pad can walk with no scroll anchor")
            if let covering {
                #expect(stamped.contains(covering.expression), "\(anchor) is drawn by a helper that stamps no anchor")
            }
        }

        // The section headers are stamped from the id each panel passes to `StreamHUDSection`, so a
        // panel that forgets it is a header the ring can leave the visible area for.
        let passed = try Self.sectionFocusIDArguments()
        #expect(passed == Set(expected.filter { $0.hasPrefix("section-") }), "a panel does not pass its section's focus id")
    }

    /// Rows whose stamp lives in a shared helper, where one occurrence in the source stands for the
    /// row each call site draws. A helper's own argument is a parameter this scan cannot resolve, so
    /// the rows it covers are named here instead.
    private static func sharedRowAnchors(_ entries: [StreamHUDFocusEntry]) -> [(expression: String, anchors: Set<String>)] {
        func rowAnchor(_ id: String) -> String? {
            StreamHUDFocusEntry.scrollAnchor(for: id, in: entries)
        }
        return [
            // The tile grids: one row per panel, anchored on the first tile it draws. The tile parity
            // test holds the grid to the model's entries, which is what makes that tile the row's anchor.
            ("tiles.first?.id", Set(["capture", "display", "input", "controllers"].compactMap { group in
                entries.first { $0.group == group }.flatMap { rowAnchor($0.id) }
            })),
            // The device pickers: one full-width row each, all drawn by `hudDropdownRow`.
            ("dropdownID", Set([NativeNVSTHostViewModel.outputDeviceDropdownID,
                                NativeNVSTHostViewModel.microphoneDeviceDropdownID,
                                NativeNVSTHostViewModel.microphoneModeDropdownID].compactMap(rowAnchor))),
            // A clipboard entry's copy and remove share the entry's row.
            ("NativeNVSTMediaStreamSurface.clipboardFocusID(for: entry)", Set(entries
                .filter { $0.id.hasPrefix(NativeNVSTHostViewModel.clipboardEntryFocusPrefix) }
                .compactMap { rowAnchor($0.id) })),
            // A guest's quality dropdown, approve and remove share the guest's row.
            ("Self.remoteCoOpQualityFocusID(for: participant)", Set(entries
                .filter { $0.id.hasPrefix(NativeNVSTHostViewModel.remoteCoOpQualityDropdownPrefix) }
                .compactMap { rowAnchor($0.id) })),
            // Every section header, stamped by `StreamHUDSection` from the id its panel passes.
            ("focusID", Set(entries.filter { $0.kind == .sectionHeader }.map(\.id))),
        ]
    }

    // MARK: - Reading the stamps out of the source

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sources(in directory: String) throws -> [String] {
        let url = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    /// The argument of every `hudFocusAnchor` call, as written. One level of nesting is enough: the
    /// anchors built from a helper are single-argument calls.
    private static func stampedAnchors() throws -> [String] {
        let pattern = try NSRegularExpression(pattern: #"\.hudFocusAnchor\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#)
        return try sources(in: "View/Stream").flatMap { source -> [String] in
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            return pattern.matches(in: source, range: range).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            }
        }
    }

    /// What each stamp resolves to: a string literal, or one of the model's own id constants, whose
    /// values are read from the model source rather than repeated here. An expression that is none of
    /// those and not a shared row is a stamp this test cannot account for, so it fails instead of
    /// being counted as covered.
    private static func resolvedAnchors(_ stamped: [String], sharedExpressions: Set<String>) throws -> [String] {
        let constants = try modelIDConstants()
        var resolved: [String] = []
        var unresolved: [String] = []
        for argument in stamped {
            if let literal = stringLiteral(argument) {
                resolved.append(literal)
            } else if let value = constants[argument] {
                resolved.append(value)
            } else if !sharedExpressions.contains(argument) {
                unresolved.append(argument)
            }
        }
        #expect(unresolved.isEmpty, "anchor expressions the scan cannot resolve: \(unresolved.sorted())")
        return resolved
    }

    /// `NativeNVSTHostViewModel.<name>` for every id constant the model declares, so a stamp that
    /// names one is read as the id it carries.
    private static func modelIDConstants() throws -> [String: String] {
        let pattern = try NSRegularExpression(pattern: #"static let (\w+) = "([^"]+)""#)
        var constants: [String: String] = [:]
        for source in try sources(in: "ViewModel/Stream") {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let name = Range(match.range(at: 1), in: source).map({ String(source[$0]) }),
                      let value = Range(match.range(at: 2), in: source).map({ String(source[$0]) }) else { continue }
                constants["NativeNVSTHostViewModel.\(name)"] = value
            }
        }
        return constants
    }

    /// The section ids the panels hand to `StreamHUDSection`, which is where a header's anchor comes
    /// from.
    private static func sectionFocusIDArguments() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"focusID: OPNStreamHUDSection\.([a-zA-Z]+)\.focusID"#)
        var ids: Set<String> = []
        for source in try sources(in: "View/Stream") {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let name = Range(match.range(at: 1), in: source).map({ String(source[$0]) }) else { continue }
                ids.insert(OPNStreamHUDSection(rawValue: name)?.focusID ?? "unknown-\(name)")
            }
        }
        return ids
    }

    private static func stringLiteral(_ argument: String) -> String? {
        guard argument.hasPrefix("\""), argument.hasSuffix("\""), argument.count >= 2 else { return nil }
        return String(argument.dropFirst().dropLast())
    }
}
