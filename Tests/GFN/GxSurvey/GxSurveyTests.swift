import Foundation
import Testing
@testable import OpenNOW

@Suite struct GxSurveyTests {
    private func context() -> GxSurveyClientContext {
        GxSurveyClientContext(
            userID: "user-123",
            idpID: "idp-456",
            deviceID: "device-789",
            deviceModel: "Mac14,14",
            deviceOSVersion: "26.6.2",
            locale: "en_GB",
            networkType: "Ethernet",
            datacenter: "Japan",
            productVersion: "0.9.0"
        )
    }

    private func configuration() -> GxSurveyConfiguration {
        .production(clientVersion: "0.9.0")
    }

    private func queryItems(of request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func feedbackRequestTargetsTheSurveyV2Endpoint() throws {
        let request = try #require(
            GxSurveyRequestFactory.feedbackSurveyRequest(configuration: configuration(), context: context())
        )
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host() == "gx-target-survey-frontend-api.gx.nvidia.com")
        #expect(request.url?.path() == "/survey/v2")

        let items = try queryItems(of: request)
        #expect(items["clientId"] == GxSurvey.clientID)
        #expect(items["triggerType"] == "FEEDBACK")
        #expect(items["readOnly"] == "false")
        #expect(items["userId"] == "user-123")
        #expect(items["idpId"] == "idp-456")
        #expect(items["deviceId"] == "device-789")
    }

    /// The endpoint validates these two case-sensitively; `MACOS`/`DESKTOP` are rejected.
    @Test func requestCarriesTheExactDeviceEnumSpellings() throws {
        let items = try queryItems(of: #require(
            GxSurveyRequestFactory.feedbackSurveyRequest(configuration: configuration(), context: context())
        ))
        #expect(items["deviceOS"] == "MacOS")
        #expect(items["deviceType"] == "Desktop")
        #expect(items["clientType"] == "Native")
    }

    @Test func clientParametersCarryTheSurveyPayload() throws {
        let json = GxSurveyRequestFactory.clientParameters(context: context())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object["network"] == "Ethernet")
        #expect(object["locale"] == "en_GB")
        #expect(object["osName"] == "MACOS")
        #expect(object["application"] == "GFN")
        #expect(object["productName"] == "GFN")
        #expect(object["productVersion"] == "0.9.0")
        #expect(object["datacenter"] == "Japan")
    }

    @Test func parserReadsTheRealFeedbackResponseShape() throws {
        let body = """
        {"sname":"PROD GFN In-App Feedback","description":"Copy of GFN In-App Feedback from Surveys",
         "tags":[],"debugInfo":{"surveySessionId":"463695e6-aeb6-4788-9298-aeb50634b19a"},
         "triggerType":"FEEDBACK","sid":"daedec77-29e9-49aa-9bab-23172eb71212","surveyVisited":false,
         "configuration":{"thank_you_toast":true,"surveyTimeout":600,"modal":true}}
        """
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let survey = try #require(GxSurveyParser.parse(json))
        #expect(survey.id == "daedec77-29e9-49aa-9bab-23172eb71212")
        #expect(survey.triggerType == "FEEDBACK")
        #expect(survey.name == "PROD GFN In-App Feedback")
        #expect(survey.surveySessionID == "463695e6-aeb6-4788-9298-aeb50634b19a")
        #expect(survey.configuration["thank_you_toast"] == "true")
        #expect(survey.configuration["surveyTimeout"] == "600")
    }

    @Test func parserRejectsAResponseWithNoSurvey() {
        #expect(GxSurveyParser.parse(["error": "none"]) == nil)
    }

    @Test func containerURLCarriesIdentitySurveyAndOptions() throws {
        let survey = GxSurveyDescriptor(
            id: "daedec77-29e9-49aa-9bab-23172eb71212",
            triggerType: "FEEDBACK",
            name: "PROD GFN In-App Feedback",
            surveySessionID: "session-1",
            configuration: ["thank_you_toast": "true", "modal": "true"]
        )
        let url = try #require(
            GxSurveyContainerURLBuilder.url(configuration: configuration(), context: context(), survey: survey)
        )
        #expect(url.host() == "gx-surveys.nvidia.com")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["surveyid"] == "daedec77-29e9-49aa-9bab-23172eb71212")
        #expect(items["clientid"] == GxSurvey.clientID)
        #expect(items["userid"] == "user-123")
        #expect(items["idpId"] == "idp-456")
        #expect(items["triggerType"] == "FEEDBACK")
        #expect(items["env"] == "PROD")
        #expect(items["version"] == "2")
        #expect(items["surveySessionId"] == "session-1")
        #expect(items["thank_you_toast"] == "true")
        #expect(items["modal"] == "true")
    }

    @Test func firstPageRequestTargetsSurveyV1WithNoPageOrAnswers() throws {
        let request = try #require(
            GxSurveyRequestFactory.firstPageRequest(configuration: configuration(), context: context(), surveyID: "sid-1")
        )
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/survey/v1")
        let items = try queryItems(of: request)
        #expect(items["sid"] == "sid-1")
        #expect(items["isPreview"] == "false")
        #expect(items["locale"] == "en-GB")
        #expect(items["pid"] == nil)
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == "{}")
    }

    @Test func submitRequestCarriesThePageIdAndAnswers() throws {
        let answers = [
            GxSurveyAnswer(questionID: "q-rating", optionIDs: ["oid-4"]),
            GxSurveyAnswer(questionID: "q-text", value: "Stutters after ten minutes"),
            GxSurveyAnswer(questionID: "q-type", optionIDs: ["oid-issues"]),
        ]
        let request = try #require(
            GxSurveyRequestFactory.submitRequest(
                configuration: configuration(),
                context: context(),
                surveyID: "sid-1",
                pageID: "pid-1",
                answers: answers
            )
        )
        #expect(request.url?.path() == "/survey/v1")
        let items = try queryItems(of: request)
        #expect(items["pid"] == "pid-1")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let encoded = try #require(json["answers"] as? [[String: Any]])
        #expect(encoded.count == 3)
        #expect(encoded[0]["qid"] as? String == "q-rating")
        #expect(encoded[0]["oids"] as? [String] == ["oid-4"])
        #expect(encoded[1]["value"] as? String == "Stutters after ten minutes")
        #expect(encoded[2]["oids"] as? [String] == ["oid-issues"])
    }

    @Test func pageParserReadsTheRealFeedbackQuestionnaire() throws {
        let body = """
        {"sid":"daedec77-29e9-49aa-9bab-23172eb71212",
         "page":{"pid":"09b13337-891d-4bb9-a976-e8d28ad857d5","title":"Survey Page","type":"SURVEY",
          "questions":[
            {"qid":"18bd118b","required":true,"question":"How would you rate GeForce NOW?","type":"CSAT",
             "options":[{"oid":"o1","oname":"1"},{"oid":"o5","oname":"5"}]},
            {"qid":"61979f49","required":true,"question":"Describe an issue or suggest an improvement","type":"TEXT","options":[]},
            {"qid":"cb355a5a","required":false,"question":"What type of feedback is this?","type":"SINGLE",
             "options":[{"oid":"i","oname":"Issues"},{"oid":"f","oname":"Feature Request"}]}
          ]},
         "is_last_page":true}
        """
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let page = try #require(GxSurveyPageParser.parse(json))
        #expect(page.id == "09b13337-891d-4bb9-a976-e8d28ad857d5")
        #expect(page.isLastPage)
        #expect(page.questions.count == 3)
        #expect(page.questions[0].kind == .csat)
        #expect(page.questions[0].kind.isRating)
        #expect(page.questions[0].options.map(\.id) == ["o1", "o5"])
        #expect(page.questions[0].options.map(\.name) == ["1", "5"])
        #expect(page.questions[1].kind == .text)
        #expect(page.questions[2].kind == .single)
        #expect(page.questions[2].options.map(\.name) == ["Issues", "Feature Request"])
        #expect(page.isNativelyRenderable)
    }

    @Test func anUnsupportedQuestionKindFallsBackToTheEmbeddedSurvey() throws {
        let body = """
        {"page":{"pid":"p","questions":[{"qid":"q","question":"Pick one","type":"DDL","options":[]}]},"is_last_page":true}
        """
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let page = try #require(GxSurveyPageParser.parse(json))
        #expect(page.questions[0].kind == .dropdown)
        #expect(!page.isNativelyRenderable)
    }
}
