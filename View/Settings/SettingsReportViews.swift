import SwiftUI

/// The support entry beside Support Diagnostics: one button into the two-channel report form.
struct ReportIssueSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    static let sections: [SettingsSection] = [
        SettingsSection("report-issue", "Report an Issue"),
    ]

    var body: some View {
        SettingsCard(title: "Report an Issue", uiScale: uiScale) {
            HStack(alignment: .top, spacing: 10 * uiScale) {
                SettingsActionButton(title: "REPORT AN ISSUE", uiScale: uiScale) {
                    OPNReportIssuePresentation.shared.present(context: .current(viewModel: viewModel))
                }
                Text("Open a pre-filled OpenNOW client report on GitHub, or send a stream quality issue to NVIDIA with a copyable session summary.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsSection("report-issue")
    }
}

extension OPNIssueReportContext {
    /// Folds the signed-in account, the selected region, and the active game onto the bundle and
    /// system facts, so a report raised from Settings carries the session it was raised in.
    @MainActor static func current(viewModel: CatalogViewModel) -> OPNIssueReportContext {
        var context = OPNIssueReportContext.appEnvironment()
        let account = SettingsAccountSnapshot(viewModel: viewModel)
        context.membershipTier = account.membershipTier
        context.region = SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: false).summary
        context.gameTitle = viewModel.activeStreamConfiguration?.title ?? ""
        context.survey = GxSurveyClientContext(
            userID: surveyIdentifier(viewModel.session.userId, viewModel.account.userId),
            idpID: surveyIdentifier(viewModel.session.idpId, viewModel.account.providerIdpId),
            deviceID: surveyIdentifier(viewModel.session.deviceId, ""),
            deviceModel: OPNSystemHardware.modelIdentifier,
            deviceOSVersion: OPNSystemHardware.operatingSystemVersion,
            locale: Locale.current.identifier,
            datacenter: context.region,
            productVersion: SettingsAppMetadata.version
        )
        return context
    }

    /// The survey endpoint expects the client's `"undefined"` marker for an identity it does not
    /// have, rather than an empty query value.
    private static func surveyIdentifier(_ primary: String, _ fallback: String) -> String {
        if !primary.isEmpty { return primary }
        return fallback.isEmpty ? "undefined" : fallback
    }
}
