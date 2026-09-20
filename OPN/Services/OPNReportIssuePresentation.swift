import Combine
import Foundation

/// Window-level state for the Report an Issue modal, and the one place that performs a submission.
///
/// The two channels are two different forms, not one form with two destinations: the client channel
/// collects a title and body for GitHub, while the stream channel collects NVIDIA's own feedback
/// questionnaire and submits it. Choosing the stream channel loads the survey immediately, so the
/// reader sees the stars and the feedback type rather than OpenNOW's report fields.
@MainActor
final class OPNReportIssuePresentation: ObservableObject {
    static let shared = OPNReportIssuePresentation()

    enum Phase: Equatable {
        case editing
        /// The client channel's optional log is being read and uploaded before the browser opens.
        case uploadingDiagnostics
        /// The NVIDIA feedback survey is being fetched.
        case fetchingSurvey
        /// NVIDIA's questions drawn as a native form.
        case surveyForm
        /// The reader must agree the feedback goes to NVIDIA, outside OpenNOW's control.
        case surveyConsent
        /// NVIDIA's own survey page, for a questionnaire the native form cannot represent.
        case surveyEmbedded(URL)
        case surveyThanks
        /// The survey could not be reached; the reader can still reach the GeForce NOW app.
        case surveyUnavailable(String)
        case sent(OPNIssueReportTarget)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .uploadingDiagnostics, .fetchingSurvey: return true
            default: return false
            }
        }

        var isSent: Bool {
            if case .sent = self { return true }
            return false
        }
    }

    @Published private(set) var isPresented = false
    @Published var draft = OPNIssueReportDraft()
    @Published private(set) var phase: Phase = .editing
    /// The questions of the native survey, and the answer being edited per question.
    @Published private(set) var surveyPage: GxSurveyPage?
    @Published private(set) var surveyAnswers: [GxSurveyAnswer] = []
    @Published private(set) var surveyErrorMessage: String?
    @Published private(set) var isSubmittingSurvey = false
    /// Whether the reader has agreed that the feedback goes to NVIDIA, outside OpenNOW's control.
    @Published private(set) var hasAgreedToExternalFeedback = false
    /// True when the client channel asked for diagnostics and the log did not upload. The report is
    /// still sent; the confirmation says so rather than failing the whole submission on a paste.
    @Published private(set) var diagnosticsUploadFailed = false

    private var context = OPNIssueReportContext()
    private var surveyID: String?
    private var surveyConfiguration = GxSurveyConfiguration.production(clientVersion: "0.0.0")
    private var surveyClientContext: GxSurveyClientContext?
    private let systemIntegration: any SystemIntegrationServing
    private let surveyService: OPNSurveyService

    init(
        systemIntegration: any SystemIntegrationServing = AppKitSystemIntegration(),
        surveyService: OPNSurveyService = .shared
    ) {
        self.systemIntegration = systemIntegration
        self.surveyService = surveyService
    }

    var isWorking: Bool {
        phase.isWorking || isSubmittingSurvey
    }

    var isSubmittable: Bool {
        OPNIssueReportComposer.isSubmittable(draft)
    }

    /// The native form's required questions all have an answer.
    var canSubmitSurvey: Bool {
        guard let page = surveyPage else { return false }
        return page.questions.allSatisfy { question in
            guard question.isRequired else { return true }
            return surveyAnswers.first { $0.questionID == question.id }?.isEmpty == false
        }
    }

    /// Opens the form with the facts the presenting surface already holds.
    func present(context: OPNIssueReportContext) {
        self.context = context
        draft = OPNIssueReportDraft()
        resetSurvey()
        diagnosticsUploadFailed = false
        phase = .editing
        isPresented = true
    }

    /// Dismissing is refused while work is in flight: the submission owns the hand-off that follows
    /// it, and closing the sheet would strand it.
    func dismiss() {
        guard !isWorking else { return }
        isPresented = false
        phase = .editing
        resetSurvey()
    }

    /// Switches channel. Selecting the stream channel loads NVIDIA's survey right away, so the form
    /// the reader sees is the survey, not the client report.
    func selectTarget(_ target: OPNIssueReportTarget) {
        guard draft.target != target else { return }
        draft.target = target
        guard target == .geforceNowStream else { return }
        loadSurveyIfNeeded()
    }

    /// Loads the survey unless it is already loaded or loading. Re-selecting retries a failure.
    func loadSurveyIfNeeded() {
        switch phase {
        case .surveyForm, .surveyEmbedded, .fetchingSurvey: return
        default: break
        }
        Task { @MainActor in
            await loadSurvey()
        }
    }

    /// Sends the client report to GitHub. The stream channel has no equivalent: its answers are
    /// submitted by `submitFeedback()`.
    func submit() {
        guard draft.target == .opennowClient, !isWorking, !phase.isSent else { return }
        guard isSubmittable else {
            phase = .failed("Choose a category, then add a summary and a description.")
            return
        }
        let draft = self.draft
        Task { @MainActor in
            var resolvedContext = context
            if draft.includesDiagnostics {
                phase = .uploadingDiagnostics
                resolvedContext.diagnosticsLogURL = await uploadDiagnostics()
                diagnosticsUploadFailed = resolvedContext.diagnosticsLogURL == nil
            }
            guard let submission = OPNIssueReportComposer.submission(for: draft, context: resolvedContext) else {
                phase = .failed("OpenNOW could not build the report link. Try again.")
                return
            }
            systemIntegration.copyToPasteboard(submission.clipboardText)
            systemIntegration.open(submission.destination)
            OPNLog.info(.app, "Opened issue report destination for \(draft.target.rawValue)")
            phase = .sent(draft.target)
        }
    }

    /// Asks the reader to agree before anything is sent to NVIDIA. The answers stay in the form, so
    /// cancelling returns to them rather than discarding the survey.
    func beginFeedbackConsent() {
        guard phase == .surveyForm else { return }
        hasAgreedToExternalFeedback = false
        phase = .surveyConsent
    }

    func cancelFeedbackConsent() {
        guard phase == .surveyConsent else { return }
        phase = .surveyForm
    }

    func setAgreedToExternalFeedback(_ agreed: Bool) {
        hasAgreedToExternalFeedback = agreed
    }

    /// Sends the agreed-on answers to NVIDIA.
    func confirmFeedbackConsent() {
        guard phase == .surveyConsent, hasAgreedToExternalFeedback else { return }
        phase = .surveyForm
        submitFeedback()
    }

    /// Sends the native form's answers to NVIDIA, or shows why it could not.
    func submitFeedback() {
        guard phase == .surveyForm, !isSubmittingSurvey, canSubmitSurvey,
              let page = surveyPage, let surveyID, let surveyClientContext else { return }
        let answers = surveyAnswers.filter { !$0.isEmpty }
        isSubmittingSurvey = true
        surveyErrorMessage = nil
        Task { @MainActor in
            do {
                let next = try await surveyService.submitFeedback(
                    configuration: surveyConfiguration,
                    context: surveyClientContext,
                    surveyID: surveyID,
                    pageID: page.id,
                    answers: answers
                )
                if let next, next.isNativelyRenderable, !next.questions.isEmpty {
                    surveyPage = next
                    surveyAnswers = next.questions.map { GxSurveyAnswer(questionID: $0.id) }
                } else {
                    OPNLog.info(.app, "Submitted the NVIDIA feedback survey")
                    phase = .surveyThanks
                }
            } catch {
                surveyErrorMessage = error.localizedDescription
                OPNLog.warning(.app, "NVIDIA feedback survey submit failed: \(error.localizedDescription)")
            }
            isSubmittingSurvey = false
        }
    }

    /// Hands a reader whose survey could not be reached off to the GeForce NOW app, or to NVIDIA's
    /// support page when it is not installed.
    func openGeForceNowFallback() {
        let fallback = URL(string: OPNIssueReportComposer.nvidiaSupportURL)
        guard let fallback else { return }
        openDestination(for: .geforceNowStream, fallback: fallback)
    }

    /// Resolves the survey: native questions when the form can draw them, otherwise the container
    /// URL that renders NVIDIA's own page. False means neither was reachable.
    private func loadSurvey() async {
        resetSurvey()
        phase = .fetchingSurvey
        if await prepareSurvey() { return }
        systemIntegration.copyToPasteboard(OPNIssueReportComposer.streamReportText(context: context))
        phase = .surveyUnavailable("NVIDIA's feedback survey could not be reached. Open the GeForce NOW app to send feedback there.")
    }

    private func prepareSurvey() async -> Bool {
        let clientContext = context.survey
            ?? GxSurveyClientContext(userID: "undefined", idpID: "undefined", deviceID: "undefined")
        let version = context.appVersion.isEmpty ? "0.0.0" : context.appVersion
        let configuration = GxSurveyConfiguration.production(clientVersion: version)
        do {
            guard let survey = try await surveyService.feedbackSurvey(configuration: configuration, context: clientContext) else {
                return false
            }
            surveyID = survey.id
            surveyConfiguration = configuration
            surveyClientContext = clientContext

            if let page = try await surveyService.feedbackPage(configuration: configuration, context: clientContext, surveyID: survey.id),
               page.isNativelyRenderable, !page.questions.isEmpty {
                surveyPage = page
                surveyAnswers = page.questions.map { GxSurveyAnswer(questionID: $0.id) }
                surveyErrorMessage = nil
                OPNLog.info(.app, "Presenting the native NVIDIA feedback survey")
                phase = .surveyForm
                return true
            }
            if let url = GxSurveyContainerURLBuilder.url(configuration: configuration, context: clientContext, survey: survey) {
                OPNLog.info(.app, "Presenting the embedded NVIDIA feedback survey")
                phase = .surveyEmbedded(url)
                return true
            }
        } catch {
            OPNLog.warning(.app, "NVIDIA feedback survey request failed: \(error.localizedDescription)")
        }
        return false
    }

    /// Sets one native answer's option ids (rating and choice questions).
    func setSurveySelection(questionID: String, optionID: String) {
        updateAnswer(questionID: questionID) { answer in
            answer.optionIDs = [optionID]
            answer.value = ""
        }
    }

    /// Adds or removes an option from a multi-select answer.
    func toggleSurveySelection(questionID: String, optionID: String) {
        updateAnswer(questionID: questionID) { answer in
            if let index = answer.optionIDs.firstIndex(of: optionID) {
                answer.optionIDs.remove(at: index)
            } else {
                answer.optionIDs.append(optionID)
            }
            answer.value = ""
        }
    }

    func setSurveyText(questionID: String, value: String) {
        updateAnswer(questionID: questionID) { answer in
            answer.value = value
            answer.optionIDs = []
        }
    }

    func surveyAnswer(for questionID: String) -> GxSurveyAnswer {
        surveyAnswers.first { $0.questionID == questionID } ?? GxSurveyAnswer(questionID: questionID)
    }

    private func updateAnswer(questionID: String, _ mutate: (inout GxSurveyAnswer) -> Void) {
        guard let index = surveyAnswers.firstIndex(where: { $0.questionID == questionID }) else { return }
        mutate(&surveyAnswers[index])
    }

    private func resetSurvey() {
        surveyID = nil
        surveyPage = nil
        surveyAnswers = []
        surveyErrorMessage = nil
        isSubmittingSurvey = false
        hasAgreedToExternalFeedback = false
        surveyClientContext = nil
    }

    /// The last-resort hand-off when neither the native form nor the embedded survey is available.
    private func openDestination(for target: OPNIssueReportTarget, fallback: URL) {
        guard target == .geforceNowStream,
              let applicationURL = systemIntegration.applicationURL(forBundleIdentifier: Self.geforceNowBundleIdentifier) else {
            systemIntegration.open(fallback)
            return
        }
        systemIntegration.openApplication(at: applicationURL)
    }

    private func uploadDiagnostics() async -> URL? {
        let logText = await OPNSentry.diagnosticsLogForUpload()
        do {
            return try await OPNSentry.uploadDiagnosticsLog(logText)
        } catch {
            OPNLog.warning(.app, "Issue report diagnostics upload failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The official NVIDIA client, by bundle id, wherever it is installed.
    private static let geforceNowBundleIdentifier = "com.nvidia.gfnpc.mall"

    #if DEBUG
    /// Seeds the form for SwiftUI previews; production always enters through `present(context:)`.
    func previewConfigure(draft: OPNIssueReportDraft, phase: Phase) {
        self.draft = draft
        self.phase = phase
    }

    /// Seeds the native survey for SwiftUI previews.
    func previewConfigureSurvey(page: GxSurveyPage, answers: [GxSurveyAnswer]) {
        draft.target = .geforceNowStream
        surveyPage = page
        surveyAnswers = answers
        phase = .surveyForm
    }
    #endif
}
