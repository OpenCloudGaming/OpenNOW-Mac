import Foundation
import Testing
@testable import OpenNOW

@Suite struct IssueReportComposerTests {
    private func context(diagnosticsLogURL: URL? = nil) -> OPNIssueReportContext {
        OPNIssueReportContext(
            appVersion: "1.2.3",
            appBuild: "45",
            bundleIdentifier: "io.github.opencloudgaming.opennow",
            macOSVersion: "Version 15.0 (Build 24A1)",
            membershipTier: "Ultimate",
            region: "np-ams-01",
            gameTitle: "Cyberpunk 2077",
            diagnosticsLogURL: diagnosticsLogURL
        )
    }

    private func draft(target: OPNIssueReportTarget = .opennowClient) -> OPNIssueReportDraft {
        var draft = OPNIssueReportDraft()
        draft.target = target
        draft.category = .bug
        draft.summary = "Controller input drops after resuming"
        draft.details = "The gamepad stops responding until I open Settings and back out."
        return draft
    }

    @Test func draftNeedsACategoryASummaryAndADescription() {
        #expect(!OPNIssueReportComposer.isSubmittable(OPNIssueReportDraft()))

        var summaryOnly = OPNIssueReportDraft()
        summaryOnly.summary = "Crash"
        #expect(!OPNIssueReportComposer.isSubmittable(summaryOnly))

        var whitespaceOnly = OPNIssueReportDraft()
        whitespaceOnly.category = .bug
        whitespaceOnly.summary = "Crash"
        whitespaceOnly.details = "   \n  "
        #expect(!OPNIssueReportComposer.isSubmittable(whitespaceOnly))

        // Everything but the category is present, and the category is what gates the send.
        var noCategory = OPNIssueReportDraft()
        noCategory.summary = "Crash"
        noCategory.details = "It crashed."
        #expect(!OPNIssueReportComposer.isSubmittable(noCategory))

        var complete = OPNIssueReportDraft()
        complete.category = .bug
        complete.summary = "Crash"
        complete.details = "It crashed."
        #expect(OPNIssueReportComposer.isSubmittable(complete))
    }

    @Test func clientSubmissionOpensGitHubIssueWithTitleAndEnvironmentBody() throws {
        let submission = try #require(
            OPNIssueReportComposer.submission(for: draft(target: .opennowClient), context: context())
        )

        #expect(submission.destination.host() == "github.com")
        #expect(submission.destination.path() == "/OpenCloudGaming/openNOW-Mac/issues/new")

        let components = try #require(URLComponents(url: submission.destination, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["title"] == "Controller input drops after resuming")
        #expect(items["labels"] == "bug")

        let body = try #require(items["body"])
        #expect(body.contains("### Category"))
        #expect(body.contains("Bug"))
        #expect(body.contains("The gamepad stops responding"))
        #expect(body.contains("OpenNOW: 1.2.3 (45)"))
        #expect(body.contains("macOS: Version 15.0 (Build 24A1)"))
        #expect(body.contains("Game: Cyberpunk 2077"))

        // The pasteboard copy is the whole report, so a dropped query is recoverable with a paste.
        #expect(submission.clipboardText.contains("### Environment"))
        // The issue body carries the machine facts but not the signed-in account.
        #expect(!submission.clipboardText.contains("Account:"))
    }

    @Test func featureRequestMapsToTheFeatureLabel() throws {
        var featureRequest = draft(target: .opennowClient)
        featureRequest.category = .featureRequest
        let submission = try #require(OPNIssueReportComposer.submission(for: featureRequest, context: context()))
        let components = try #require(URLComponents(url: submission.destination, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["labels"] == "feature")
        #expect(submission.clipboardText.contains("Feature Request"))
    }

    /// Both categories map to a label the repository actually has, so the issue is never uncategorised.
    @Test func everyCategoryCarriesAnExistingLabel() {
        #expect(OPNIssueReportCategory.allCases.map(\.githubLabel) == ["bug", "feature"])
    }

    @Test func clientSubmissionLinksDiagnosticsLogWhenPresent() throws {
        let logURL = try #require(URL(string: "https://paste.c-net.org/AbCdEf"))
        let submission = try #require(
            OPNIssueReportComposer.submission(
                for: draft(target: .opennowClient),
                context: context(diagnosticsLogURL: logURL)
            )
        )
        #expect(submission.clipboardText.contains("Diagnostics log: https://paste.c-net.org/AbCdEf"))
    }

    /// The stream channel has no link and no summary: its feedback is NVIDIA's survey, and this
    /// text is only the session facts kept for when that survey cannot be reached.
    @Test func streamChannelProducesNoSubmission() {
        #expect(OPNIssueReportComposer.submission(for: draft(target: .geforceNowStream), context: context()) == nil)
    }

    @Test func streamFallbackTextCarriesOnlyTheSessionFacts() {
        let text = OPNIssueReportComposer.streamReportText(context: context())
        #expect(!text.contains("Summary:"))
        #expect(!text.contains("Details:"))
        #expect(text.contains("GeForce NOW stream feedback"))
        #expect(text.contains("Game: Cyberpunk 2077"))
        #expect(text.contains("unofficial GeForce NOW client"))
    }

    @Test func environmentLinesDropFieldsThatAreNotPresent() {
        let bare = OPNIssueReportContext(appVersion: "1.2.3", appBuild: "45")
        #expect(OPNIssueReportComposer.environmentLines(context: bare) == ["OpenNOW: 1.2.3 (45)"])

        let unknown = OPNIssueReportContext()
        #expect(OPNIssueReportComposer.environmentLines(context: unknown) == ["OpenNOW: Unknown"])
    }

    @Test func appEnvironmentReadsIdentityFromTheBundleDictionary() {
        let environment = OPNIssueReportContext.appEnvironment(
            infoDictionary: [
                "CFBundleShortVersionString": "9.9.9",
                "CFBundleVersion": "123",
            ],
            operatingSystemVersion: "macOS Test 1.0"
        )
        #expect(environment.appVersion == "9.9.9")
        #expect(environment.appBuild == "123")
        #expect(environment.macOSVersion == "macOS Test 1.0")
    }

    @Test func anOverlongBodyIsCappedInTheQueryButKeptInFullOnThePasteboard() throws {
        var long = draft(target: .opennowClient)
        long.details = String(repeating: "x", count: OPNIssueReportComposer.maximumQueryBodyLength + 500)
        let submission = try #require(OPNIssueReportComposer.submission(for: long, context: context()))

        let components = try #require(URLComponents(url: submission.destination, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let body = try #require(items["body"])
        #expect(body.count <= OPNIssueReportComposer.maximumQueryBodyLength + 64)
        #expect(body.contains("full report copied to your clipboard"))

        #expect(submission.clipboardText.count > OPNIssueReportComposer.maximumQueryBodyLength)
    }
}
