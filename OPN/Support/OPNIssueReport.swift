import Foundation

/// Which support channel a report is addressed to.
///
/// GeForce NOW owns the stream itself and OpenNOW is an unofficial client in front of it, so a
/// picture-quality or latency problem is NVIDIA's to fix while a catalog, controller, or UI problem
/// is OpenNOW's. The two destinations are kept side by side, rather than hidden behind one "submit"
/// button, so the reader picks the channel that can actually act on the report.
enum OPNIssueReportTarget: String, CaseIterable, Identifiable, Sendable {
    case opennowClient
    case geforceNowStream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opennowClient: return "OpenNOW Client"
        case .geforceNowStream: return "GeForce NOW Stream"
        }
    }

    var subtitle: String {
        switch self {
        case .opennowClient:
            return "Catalog, controller, audio, settings, or the app itself."
        case .geforceNowStream:
            return "Picture quality, latency, or a game running on NVIDIA's servers."
        }
    }

    /// Who receives the report, for the footer and the confirmation copy.
    var destinationName: String {
        switch self {
        case .opennowClient: return "GitHub"
        case .geforceNowStream: return "NVIDIA"
        }
    }
}

/// The machine and session facts attached to a report.
///
/// Assembled by the caller from the surfaces that already know them, so the composer stays free of
/// app singletons and is unit-testable. Every field is optional text: a report from the Help menu
/// has no account or route, and the composer drops the empty lines rather than printing blanks.
struct OPNIssueReportContext: Equatable, Sendable {
    var appVersion: String
    var appBuild: String
    var bundleIdentifier: String
    var macOSVersion: String
    var membershipTier: String
    var region: String
    var gameTitle: String
    var diagnosticsLogURL: URL?
    /// The identity the NVIDIA feedback survey carries. Nil when the presenting surface has no
    /// session to read it from, such as the Help menu.
    var survey: GxSurveyClientContext?

    init(
        appVersion: String = "",
        appBuild: String = "",
        bundleIdentifier: String = "",
        macOSVersion: String = "",
        membershipTier: String = "",
        region: String = "",
        gameTitle: String = "",
        diagnosticsLogURL: URL? = nil,
        survey: GxSurveyClientContext? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.macOSVersion = macOSVersion
        self.membershipTier = membershipTier
        self.region = region
        self.gameTitle = gameTitle
        self.diagnosticsLogURL = diagnosticsLogURL
        self.survey = survey
    }

    /// The identity that is always available, from the bundle and the running system. Callers that
    /// hold a `CatalogViewModel` fold the account, membership, region, and active game on top.
    static func appEnvironment(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> OPNIssueReportContext {
        OPNIssueReportContext(
            appVersion: stringValue(infoDictionary["CFBundleShortVersionString"]),
            appBuild: stringValue(infoDictionary["CFBundleVersion"]),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? stringValue(infoDictionary["CFBundleIdentifier"]),
            macOSVersion: operatingSystemVersion
        )
    }

    private static func stringValue(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// What kind of OpenNOW client problem is being reported. The category is a GitHub label as well as
/// a body section, so it survives into the issue either way.
enum OPNIssueReportCategory: String, CaseIterable, Identifiable, Sendable {
    case bug
    case featureRequest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: return "Bug"
        case .featureRequest: return "Feature Request"
        }
    }

    /// The repository label this category pre-selects on the new-issue form. Both labels exist on
    /// the repository, so the issue arrives already categorised.
    var githubLabel: String {
        switch self {
        case .bug: return "bug"
        case .featureRequest: return "feature"
        }
    }
}

/// What the reader typed into the report form.
struct OPNIssueReportDraft: Equatable, Sendable {
    var target: OPNIssueReportTarget = .opennowClient
    var category: OPNIssueReportCategory?
    var summary: String = ""
    var details: String = ""
    var includesDiagnostics: Bool = true

    var trimmedSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDetails: String { details.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A ready-to-perform submission: where to send the reader, and what to leave on the pasteboard so
/// the report survives a link the browser or the receiving form declines to carry whole.
struct OPNIssueReportSubmission: Equatable, Sendable {
    let destination: URL
    let clipboardText: String
}

/// Builds the two report destinations and their text from a draft and a context.
///
/// Pure and synchronous: it resolves no URL scheme and uploads nothing, so the caller owns opening
/// the browser, touching the pasteboard, and the optional diagnostics upload.
enum OPNIssueReportComposer {
    /// `issues/new` accepts `title` and `body` query items on the repository that owns this app.
    static let repositoryIssueURL = "https://github.com/OpenCloudGaming/openNOW-Mac/issues/new"

    /// NVIDIA's GeForce NOW support landing page, which routes a stream problem to Customer Care
    /// and the knowledgebase. GeForce NOW's own in-app feedback is a session-loaded survey with no
    /// stable deep link, so the client cannot open the same form and points here instead.
    static let nvidiaSupportURL = "https://www.nvidia.com/en-us/geforce-now/support/"

    /// The longest body that goes into the issue query string. A browser or GitHub can drop a
    /// sufficiently long URL, and a dropped body silently loses the reader's words; the full report
    /// is always on the pasteboard, so the query is capped rather than the text.
    static let maximumQueryBodyLength = 6000

    /// The client report needs a category, a name, and a body. The summary is the GitHub issue
    /// title, and an issue with no description is one nobody can reproduce.
    static func isSubmittable(_ draft: OPNIssueReportDraft) -> Bool {
        draft.category != nil && !draft.trimmedSummary.isEmpty && !draft.trimmedDetails.isEmpty
    }

    /// Only the client channel produces a link for the reader to finish. The stream channel has no
    /// link: its feedback is submitted through NVIDIA's survey endpoints instead.
    static func submission(for draft: OPNIssueReportDraft, context: OPNIssueReportContext) -> OPNIssueReportSubmission? {
        guard draft.target == .opennowClient, isSubmittable(draft) else { return nil }
        return clientSubmission(draft: draft, context: context)
    }

    /// The full markdown body carried by both the issue link and the pasteboard. The pasteboard
    /// copy is what makes a truncated query recoverable with a paste.
    static func clientIssueBody(draft: OPNIssueReportDraft, context: OPNIssueReportContext) -> String {
        var lines = [
            "### Category",
            draft.category?.title ?? "Unspecified",
            "",
            "### What happened",
            draft.trimmedDetails,
            "",
            "### Environment",
        ]
        lines.append(contentsOf: environmentLines(context: context).map { "- \($0)" })
        if let url = context.diagnosticsLogURL {
            lines.append("- Diagnostics log: \(url.absoluteString)")
        }
        lines.append("")
        lines.append("_Reported from OpenNOW's Report an Issue form._")
        return lines.joined(separator: "\n")
    }

    /// The clipboard text kept for the stream channel when NVIDIA's survey cannot be reached. It
    /// carries only the session facts — the survey supplies its own description field.
    static func streamReportText(context: OPNIssueReportContext) -> String {
        var lines = [
            "GeForce NOW stream feedback",
            "",
            "Session:",
        ]
        lines.append(contentsOf: environmentLines(context: context).map { "- \($0)" })
        lines.append("")
        lines.append("Paste this into NVIDIA's feedback form if it asks for details.")
        lines.append("OpenNOW is an unofficial GeForce NOW client; the stream itself runs on NVIDIA's servers.")
        return lines.joined(separator: "\n")
    }

    /// The facts both bodies share, one per line, with empty fields dropped.
    static func environmentLines(context: OPNIssueReportContext) -> [String] {
        var lines: [String] = []
        let version = context.appVersion.isEmpty ? "Unknown" : context.appVersion
        let build = context.appBuild.isEmpty ? "" : " (\(context.appBuild))"
        lines.append("OpenNOW: \(version)\(build)")
        append(&lines, "Bundle", context.bundleIdentifier)
        append(&lines, "macOS", context.macOSVersion)
        append(&lines, "Membership", context.membershipTier)
        append(&lines, "Region", context.region)
        append(&lines, "Game", context.gameTitle)
        return lines
    }

    private static func append(_ lines: inout [String], _ label: String, _ value: String) {
        guard !value.isEmpty else { return }
        lines.append("\(label): \(value)")
    }

    private static func clientSubmission(draft: OPNIssueReportDraft, context: OPNIssueReportContext) -> OPNIssueReportSubmission? {
        guard var components = URLComponents(string: repositoryIssueURL) else { return nil }
        let body = clientIssueBody(draft: draft, context: context)
        var items = [
            URLQueryItem(name: "title", value: draft.trimmedSummary),
            URLQueryItem(name: "body", value: truncatedQueryBody(body)),
        ]
        if let label = draft.category?.githubLabel {
            items.append(URLQueryItem(name: "labels", value: label))
        }
        components.queryItems = items
        guard let destination = components.url else { return nil }
        return OPNIssueReportSubmission(destination: destination, clipboardText: body)
    }

    private static func truncatedQueryBody(_ body: String) -> String {
        guard body.count > maximumQueryBodyLength else { return body }
        return String(body.prefix(maximumQueryBodyLength)) + "\n\n…(full report copied to your clipboard)"
    }
}
