import Foundation
import Testing
@testable import OpenNOW

@Suite struct ReleaseNotesFormatterTests {
    private let releasePleaseBody = """
    ## [0.2.0](https://github.com/OpenCloudGaming/OpenNOW-Mac/compare/v0.1.0...v0.2.0) (2026-08-31)


    ### Features

    * add desktop mode action on controller mode ui ([5436546](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/5436546ad81b9a97ef2c98729948f821149a8339))
    * add discord rich presence ([#22](https://github.com/OpenCloudGaming/OpenNOW-Mac/issues/22)) ([4727db5](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/4727db58d28ded1f8aa5a16a884e1660afc4fb38))

    ### Bug Fixes

    * **ci:** install dmgbuild and sign release with real entitlements ([055e530](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/055e5309a9e2d1a2b6a2ee4d47a6a1a4a0b2c3d4))
    """

    private let generatedBody = """
    ## What's Changed
    * Fix pillarbox geometry by @anderson-oki in https://github.com/OpenCloudGaming/OpenNOW-Mac/pull/41
    * Bump the decode budget by @someone-else in https://github.com/OpenCloudGaming/OpenNOW-Mac/pull/42

    **Full Changelog**: https://github.com/OpenCloudGaming/OpenNOW-Mac/compare/v0.1.0...v0.2.0
    """

    @Test func parsesReleasePleaseSections() {
        let notes = OpenNOWReleaseNotesFormatter.parse(releasePleaseBody)

        #expect(notes.sections.count == 2)
        #expect(notes.sections[0].title == "Features")
        #expect(notes.sections[0].kind == .features)
        #expect(notes.sections[1].title == "Bug Fixes")
        #expect(notes.sections[1].kind == .fixes)
        #expect(notes.entryCount == 3)
    }

    @Test func liftsVersionHeadingIntoCompareURL() {
        let notes = OpenNOWReleaseNotesFormatter.parse(releasePleaseBody)

        #expect(notes.compareURL?.absoluteString == "https://github.com/OpenCloudGaming/OpenNOW-Mac/compare/v0.1.0...v0.2.0")
        #expect(notes.sections.allSatisfy { !$0.title.contains("0.2.0") })
    }

    @Test func stripsCommitLinkIntoShortSHA() {
        let notes = OpenNOWReleaseNotesFormatter.parse(releasePleaseBody)
        let entry = notes.sections[0].entries[0]

        #expect(entry.text == "Add desktop mode action on controller mode ui")
        #expect(entry.commitShortSHA == "5436546")
        #expect(entry.commitURL?.absoluteString.hasSuffix("5436546ad81b9a97ef2c98729948f821149a8339") == true)
        #expect(entry.pullRequest == nil)
    }

    @Test func stripsBothIssueAndCommitLinks() {
        let notes = OpenNOWReleaseNotesFormatter.parse(releasePleaseBody)
        let entry = notes.sections[0].entries[1]

        #expect(entry.text == "Add discord rich presence")
        #expect(entry.commitShortSHA == "4727db5")
        #expect(entry.pullRequest == 22)
        #expect(entry.pullRequestURL?.absoluteString.hasSuffix("/issues/22") == true)
    }

    @Test func keepsBoldScopePrefixUntouched() {
        let notes = OpenNOWReleaseNotesFormatter.parse(releasePleaseBody)
        let entry = notes.sections[1].entries[0]

        #expect(entry.text == "**ci:** install dmgbuild and sign release with real entitlements")
        #expect(entry.commitShortSHA == "055e530")
    }

    @Test func parsesGeneratedNotesAttribution() {
        let notes = OpenNOWReleaseNotesFormatter.parse(generatedBody)
        let entry = notes.sections[0].entries[0]

        #expect(entry.text == "Fix pillarbox geometry")
        #expect(entry.author == "anderson-oki")
        #expect(entry.pullRequest == 41)
        #expect(notes.compareURL?.absoluteString.hasSuffix("v0.1.0...v0.2.0") == true)
    }

    @Test func keepsUnrecognisedProseInsteadOfDroppingIt() {
        let notes = OpenNOWReleaseNotesFormatter.parse("This build needs a full reinstall.\n\nSorry about that.")

        #expect(notes.sections.isEmpty)
        #expect(notes.paragraphs == ["This build needs a full reinstall.", "Sorry about that."])
        #expect(!notes.isEmpty)
    }

    @Test func groupsBulletsWithoutHeadingUnderFallbackSection() {
        let notes = OpenNOWReleaseNotesFormatter.parse("- first thing\n- second thing")

        #expect(notes.sections.count == 1)
        #expect(notes.sections[0].title == "Changes")
        #expect(notes.sections[0].kind == .other)
        #expect(notes.sections[0].entries.map(\.text) == ["First thing", "Second thing"])
    }

    @Test func joinsWrappedBulletContinuationLines() {
        let notes = OpenNOWReleaseNotesFormatter.parse("### Features\n\n* add a very long entry\n  that wrapped across lines")

        #expect(notes.sections[0].entries[0].text == "Add a very long entry that wrapped across lines")
    }

    @Test func emptyBodyProducesEmptyNotes() {
        #expect(OpenNOWReleaseNotesFormatter.parse("").isEmpty)
        #expect(OpenNOWReleaseNotesFormatter.parse("\n\n   \n").isEmpty)
    }

    @Test func attributedTextFallsBackToPlainOnBrokenMarkdown() {
        let attributed = OpenNOWReleaseNotesFormatter.attributedText("plain **bold** text")

        #expect(String(attributed.characters) == "plain bold text")
    }
}
