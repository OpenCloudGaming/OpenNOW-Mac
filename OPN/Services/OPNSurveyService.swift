import Foundation

/// Drives the GeForce NOW in-app feedback survey: fetches the survey, loads its questions, and
/// submits the reader's answers — the same unauthenticated `/survey` endpoints the official client
/// calls. A failure here is not fatal: the report falls back to NVIDIA's own embedded survey, then
/// to the GeForce NOW app or NVIDIA support.
@MainActor
final class OPNSurveyService {
    static let shared = OPNSurveyService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The feedback survey NVIDIA targets at this account, or nil when there is none.
    func feedbackSurvey(configuration: GxSurveyConfiguration, context: GxSurveyClientContext) async throws -> GxSurveyDescriptor? {
        guard let request = GxSurveyRequestFactory.feedbackSurveyRequest(configuration: configuration, context: context) else {
            throw OPNSurveyServiceError.invalidRequest
        }
        return GxSurveyParser.parse(try await perform(request))
    }

    /// The container URL that renders the survey — used when the questions are not something a
    /// native form can draw.
    func feedbackSurveyURL(configuration: GxSurveyConfiguration, context: GxSurveyClientContext) async throws -> URL? {
        guard let survey = try await feedbackSurvey(configuration: configuration, context: context) else { return nil }
        return GxSurveyContainerURLBuilder.url(configuration: configuration, context: context, survey: survey)
    }

    /// The survey's first page of questions.
    func feedbackPage(configuration: GxSurveyConfiguration, context: GxSurveyClientContext, surveyID: String) async throws -> GxSurveyPage? {
        guard let request = GxSurveyRequestFactory.firstPageRequest(configuration: configuration, context: context, surveyID: surveyID) else {
            throw OPNSurveyServiceError.invalidRequest
        }
        return GxSurveyPageParser.parse(try await perform(request))
    }

    /// Submits one page's answers and returns the next page, or nil when the survey is complete.
    func submitFeedback(
        configuration: GxSurveyConfiguration,
        context: GxSurveyClientContext,
        surveyID: String,
        pageID: String,
        answers: [GxSurveyAnswer]
    ) async throws -> GxSurveyPage? {
        guard let request = GxSurveyRequestFactory.submitRequest(
            configuration: configuration,
            context: context,
            surveyID: surveyID,
            pageID: pageID,
            answers: answers
        ) else {
            throw OPNSurveyServiceError.invalidRequest
        }
        return GxSurveyPageParser.parse(try await perform(request))
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OPNSurveyServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw OPNSurveyServiceError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { return [:] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OPNSurveyServiceError.invalidResponse
        }
        return json
    }
}

enum OPNSurveyServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The NVIDIA feedback survey request could not be built."
        case .invalidResponse: return "The NVIDIA feedback survey returned an unreadable response."
        case .httpStatus(let code): return "The NVIDIA feedback survey returned HTTP \(code)."
        }
    }
}
