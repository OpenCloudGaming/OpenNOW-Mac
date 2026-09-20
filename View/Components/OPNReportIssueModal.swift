import SwiftUI

/// Window-level host for the Report an Issue modal. Mounted once at the app root so the form
/// reaches the catalog, the login wall, and Settings through the same path.
struct OPNReportIssueOverlay: View {
    @ObservedObject private var presentation = OPNReportIssuePresentation.shared
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        if presentation.isPresented {
            GeometryReader { proxy in
                ZStack {
                    OPNDesign.Surface.scrim
                        .ignoresSafeArea()
                        .onTapGesture { presentation.dismiss() }

                    OPNReportIssueModal(
                        presentation: presentation,
                        uiScale: uiScale,
                        availableSize: proxy.size
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .transition(.opacity)
        }
    }
}

/// App-shell support form following the modal spec: Panel background, 1px Stroke Regular, 2px accent
/// top bar, modal shadow, App Bar header, and a square-button footer.
///
/// The channel picker chooses between two different forms rather than one form with two
/// destinations: OpenNOW Client collects a title and body for GitHub, GeForce NOW Stream draws
/// NVIDIA's feedback survey (stars, free text, feedback type) and submits it to NVIDIA. Selecting
/// the stream channel loads the survey immediately, so its star rating is what the reader sees.
struct OPNReportIssueModal: View {
    @ObservedObject var presentation: OPNReportIssuePresentation
    let uiScale: CGFloat
    let availableSize: CGSize

    @Environment(\.openURL) private var openURL

    private var panelWidth: CGFloat {
        let windowWidth = availableSize.width - OPNDesign.Spacing.pageHorizontal(scale: uiScale) * 2
        return max(min(520 * uiScale, windowWidth), 340 * uiScale)
    }

    /// The report body can run taller than the window at a high interface scale; it alone scrolls,
    /// so the header and footer stay put. The embedded survey gets more room than the report form.
    private var bodyMaxHeight: CGFloat {
        max(min(470 * uiScale, availableSize.height * 0.62), 180 * uiScale)
    }

    private var surveyHeight: CGFloat {
        max(min(580 * uiScale, availableSize.height * 0.74), 320 * uiScale)
    }

    /// The native survey is the tallest body the modal draws, and its three questions should fit
    /// without scrolling in an ordinary window. The cap is the window minus the chrome the header,
    /// footer, and rules occupy, so the panel still stays inside the window at a high interface
    /// scale and only scrolls when the content genuinely cannot fit.
    private var surveyFormMaxHeight: CGFloat {
        max(availableSize.height - 145 * uiScale, 280 * uiScale)
    }

    /// Selecting a channel goes through the presentation so the stream channel starts loading the
    /// survey the moment it is chosen.
    private var targetSelection: Binding<OPNIssueReportTarget> {
        Binding(get: { presentation.draft.target }, set: { presentation.selectTarget($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            header

            rule

            bodyArea

            rule

            footer
        }
        .frame(width: panelWidth)
        .background(OPNDesign.Surface.panel)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28 * uiScale, y: 20 * uiScale)
        .onExitCommand { presentation.dismiss() }
    }

    private var rule: some View {
        Rectangle()
            .fill(OPNDesign.Stroke.subtle)
            .frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text("SUPPORT")
                    .font(.uiSans(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accent)
                    .tracking(1.1)
                Text("Feedback")
                    .font(.uiSans(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
            }
            Spacer(minLength: OPNDesign.Spacing.xSmall(scale: uiScale))
            OPNModalCloseButton(uiScale: uiScale) { presentation.dismiss() }
                .disabled(presentation.isWorking)
                .opacity(presentation.isWorking ? 0.4 : 1)
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.medium(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OPNDesign.Surface.appBar)
    }

    @ViewBuilder
    private var bodyArea: some View {
        switch presentation.draft.target {
        case .opennowClient: clientBody
        case .geforceNowStream: streamBody
        }
    }

    @ViewBuilder
    private var clientBody: some View {
        if case .sent(let target) = presentation.phase {
            OPNReportIssueConfirmation(
                target: target,
                diagnosticsUploadFailed: presentation.diagnosticsUploadFailed,
                uiScale: uiScale
            )
            .padding(OPNDesign.Spacing.card(scale: uiScale))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            scrollingForm { clientFields }
        }
    }

    @ViewBuilder
    private var streamBody: some View {
        switch presentation.phase {
        case .surveyEmbedded(let url):
            OPNFeedbackSurveyView(url: url)
                .frame(height: surveyHeight)
        case .surveyThanks:
            surveyThanksArea
        case .surveyForm, .surveyConsent:
            scrollingForm(maxHeight: surveyFormMaxHeight) { streamContent }
        default:
            plainForm { streamContent }
        }
    }

    /// The channel picker stays above whichever form the channel draws. The scroll view is sized to
    /// its content (`fixedSize`) and only capped, so a short form does not stretch the panel and a
    /// tall one scrolls rather than overflowing the window.
    private func scrollingForm<Content: View>(maxHeight: CGFloat? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical) {
            formStack(content)
        }
        .frame(maxHeight: maxHeight ?? bodyMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The same layout without a scroll container, for the short loading and unavailable states that
    /// would otherwise be stretched to a fixed cap.
    private func plainForm<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        formStack(content)
    }

    private func formStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.contentVertical(scale: uiScale)) {
            OPNReportIssueTargetPicker(selection: targetSelection, uiScale: uiScale)
            content()
        }
        .padding(OPNDesign.Spacing.card(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clientFields: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.contentVertical(scale: uiScale)) {
            OPNReportIssueCategoryPicker(selection: $presentation.draft.category, uiScale: uiScale)

            OPNReportIssueInput(
                label: "Summary",
                placeholder: "One line describing the problem",
                text: $presentation.draft.summary,
                uiScale: uiScale
            )

            OPNReportIssueInput(
                label: "Description",
                placeholder: "What you did, what you expected, and what happened instead",
                isMultiline: true,
                text: $presentation.draft.details,
                uiScale: uiScale
            )

            OPNReportIssueCheckbox(
                title: "Include diagnostics",
                subtitle: "Uploads the sanitized current-run log and links it in the report.",
                isOn: $presentation.draft.includesDiagnostics,
                uiScale: uiScale
            )

            if case .failed(let message) = presentation.phase {
                errorText(message)
            }
        }
    }

    @ViewBuilder
    private var streamContent: some View {
        switch presentation.phase {
        case .surveyForm:
            OPNFeedbackSurveyForm(presentation: presentation, uiScale: uiScale)
        case .surveyConsent:
            surveyConsentContent
        case .surveyUnavailable(let message):
            OPNReportIssueNotice(text: message, uiScale: uiScale)
        default:
            loadingArea("Loading NVIDIA feedback…")
        }
    }

    /// The agreement gate before anything is sent: it names NVIDIA as the recipient and states
    /// plainly that OpenNOW cannot see, change, or follow up on what the reader submits.
    private var surveyConsentContent: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.contentVertical(scale: uiScale)) {
            OPNReportIssueNotice(
                text: "Your answers are sent directly to NVIDIA as GeForce NOW feedback. OpenNOW is an independent client, is not affiliated with or endorsed by NVIDIA, and cannot see, change, or follow up on what you submit.",
                uiScale: uiScale
            )
            OPNReportIssueCheckbox(
                title: "I understand and agree",
                subtitle: "My feedback goes to NVIDIA, outside OpenNOW's control.",
                isOn: agreedToExternalFeedback,
                uiScale: uiScale
            )
        }
    }

    private var agreedToExternalFeedback: Binding<Bool> {
        Binding(
            get: { presentation.hasAgreedToExternalFeedback },
            set: { presentation.setAgreedToExternalFeedback($0) }
        )
    }

    private var surveyThanksArea: some View {
        HStack(spacing: 10 * uiScale) {
            ZStack {
                Rectangle().fill(OPNDesign.accent.opacity(0.16))
                Image(systemName: "checkmark")
                    .font(.uiSans(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
            }
            .frame(width: 40 * uiScale, height: 40 * uiScale)
            .overlay { Rectangle().strokeBorder(OPNDesign.accent.opacity(0.42), lineWidth: 1) }

            VStack(alignment: .leading, spacing: 4 * uiScale) {
                Text("Thanks for your feedback")
                    .font(.uiSans(size: 16 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                Text("NVIDIA received your survey response.")
                    .font(.uiSans(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(OPNDesign.Spacing.card(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.uiSans(size: 12 * uiScale, weight: .bold))
            .foregroundStyle(OPNDesign.Semantic.destructive)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loadingArea(_ text: String) -> some View {
        VStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VendorIndeterminateProgressBar()
                .frame(width: 160 * uiScale, height: 3 * uiScale)
            Text(text)
                .font(.uiSans(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(OPNDesign.Spacing.xxLarge(scale: uiScale))
    }

    private var footer: some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Spacer(minLength: OPNDesign.Spacing.xSmall(scale: uiScale))
            footerButtons
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch presentation.draft.target {
        case .opennowClient: clientFooterButtons
        case .geforceNowStream: streamFooterButtons
        }
    }

    @ViewBuilder
    private var clientFooterButtons: some View {
        if case .sent = presentation.phase {
            Button("CLOSE") { presentation.dismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.defaultAction)
        } else {
            Button("CANCEL") { presentation.dismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
                .disabled(presentation.isWorking)

            Button(clientSubmitTitle) { presentation.submit() }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .disabled(!presentation.isSubmittable || presentation.isWorking)
                .opacity(presentation.isSubmittable && !presentation.isWorking ? 1 : 0.62)
        }
    }

    @ViewBuilder
    private var streamFooterButtons: some View {
        switch presentation.phase {
        case .surveyEmbedded(let url):
            Button("OPEN IN BROWSER") { openURL(url) }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
            Button("DONE") { presentation.dismiss() }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.defaultAction)
        case .surveyThanks:
            Button("CLOSE") { presentation.dismiss() }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.defaultAction)
        case .surveyForm:
            Button("CANCEL") { presentation.dismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
                .disabled(presentation.isWorking)

            Button(presentation.isSubmittingSurvey ? "SUBMITTING…" : "SUBMIT FEEDBACK") { presentation.beginFeedbackConsent() }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .disabled(!presentation.canSubmitSurvey || presentation.isWorking)
                .opacity(presentation.canSubmitSurvey && !presentation.isWorking ? 1 : 0.62)
        case .surveyConsent:
            Button("CANCEL") { presentation.cancelFeedbackConsent() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)

            Button("AGREE & SEND") { presentation.confirmFeedbackConsent() }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .disabled(!presentation.hasAgreedToExternalFeedback)
                .opacity(presentation.hasAgreedToExternalFeedback ? 1 : 0.62)
                .keyboardShortcut(.defaultAction)
        case .surveyUnavailable:
            Button("CANCEL") { presentation.dismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
            Button("OPEN GEFORCE NOW") { presentation.openGeForceNowFallback() }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.defaultAction)
        default:
            Button("CANCEL") { presentation.dismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
                .disabled(presentation.isWorking)
            Button("LOADING…") {}
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .disabled(true)
                .opacity(0.62)
        }
    }

    /// The client channel is the only one that uploads diagnostics before opening a link.
    private var clientSubmitTitle: String {
        if case .uploadingDiagnostics = presentation.phase { return "SENDING…" }
        return "SEND REPORT"
    }
}

#if DEBUG
private struct OPNReportIssueModalPreview: View {
    let target: OPNIssueReportTarget
    let phase: OPNReportIssuePresentation.Phase
    var uiScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OPNDesign.Surface.app
                OPNReportIssueModal(
                    presentation: previewPresentation,
                    uiScale: uiScale,
                    availableSize: proxy.size
                )
            }
        }
        .frame(width: 900 * uiScale, height: 700 * uiScale)
    }

    private var previewPresentation: OPNReportIssuePresentation {
        let presentation = OPNReportIssuePresentation()
        var draft = OPNIssueReportDraft()
        draft.target = target
        draft.summary = "Controller input drops after resuming"
        draft.details = "After resuming a session, the gamepad stops responding until I open Settings and back out."
        presentation.previewConfigure(draft: draft, phase: phase)
        return presentation
    }
}

private struct OPNSurveyFormPreview: View {
    var uiScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OPNDesign.Surface.app
                OPNReportIssueModal(
                    presentation: previewPresentation,
                    uiScale: uiScale,
                    availableSize: proxy.size
                )
            }
        }
        .frame(width: 900 * uiScale, height: 700 * uiScale)
    }

    private var previewPresentation: OPNReportIssuePresentation {
        let presentation = OPNReportIssuePresentation()
        presentation.previewConfigureSurvey(page: Self.page, answers: Self.answers)
        return presentation
    }

    private static let page = GxSurveyPage(
        id: "pid-1",
        questions: [
            GxSurveyQuestion(id: "q1", text: "How would you rate GeForce NOW?", kind: .csat, isRequired: true, options: [
                GxSurveyOption(id: "o1", name: "1"),
                GxSurveyOption(id: "o2", name: "2"),
                GxSurveyOption(id: "o3", name: "3"),
                GxSurveyOption(id: "o4", name: "4"),
                GxSurveyOption(id: "o5", name: "5"),
            ]),
            GxSurveyQuestion(id: "q2", text: "Describe an issue or suggest an improvement", kind: .text, isRequired: true, options: []),
            GxSurveyQuestion(id: "q3", text: "What type of feedback is this?", kind: .single, isRequired: false, options: [
                GxSurveyOption(id: "i", name: "Issues"),
                GxSurveyOption(id: "f", name: "Feature Request"),
                GxSurveyOption(id: "g", name: "Game Request"),
                GxSurveyOption(id: "o", name: "Other"),
            ]),
        ],
        isLastPage: true
    )

    private static let answers = [
        GxSurveyAnswer(questionID: "q1", optionIDs: ["o4"]),
        GxSurveyAnswer(questionID: "q2"),
        GxSurveyAnswer(questionID: "q3", optionIDs: ["i"]),
    ]
}

#Preview("Client report") {
    OPNReportIssueModalPreview(target: .opennowClient, phase: .editing)
}

#Preview("Stream survey") {
    OPNSurveyFormPreview()
}

#Preview("Client sent") {
    OPNReportIssueModalPreview(target: .opennowClient, phase: .sent(.opennowClient))
}

#Preview("Stream survey @ 1.5x") {
    OPNSurveyFormPreview(uiScale: 1.5)
}
#endif
