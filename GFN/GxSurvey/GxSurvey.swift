import Foundation

/// The GeForce NOW in-app survey frontend, as the official macOS client uses it.
///
/// "Send Feedback" is not a web page: the client asks this service for a feedback survey and then
/// renders the returned survey in an embedded browser. The endpoint is unauthenticated — identity
/// travels in the query string — so a third-party client can drive the same flow and embed the same
/// survey. This file is the executable specification of that request; the live call lives in
/// `OPNSurveyService`.
enum GxSurvey {
    /// The trigger the client uses for its "Send Feedback" entry.
    static let feedbackTriggerType = "FEEDBACK"

    /// The survey client id the GeForce NOW macOS client registers under.
    static let clientID = "78589530426925203"

    static let productionServer = "https://gx-target-survey-frontend-api.gx.nvidia.com"
    static let stagingServer = "https://gx-target-survey-frontend-api.gx-stg.nvidia.com"
    static let productionContainerBaseURL = "https://gx-surveys.nvidia.com"
    static let productionEnvironment = "PROD"
    static let apiVersion = "v2"
    static let containerVersion = "2"

    /// The response's `deviceOS`/`deviceType` are validated case-sensitively: these exact spellings
    /// are what the client sends, and anything else is rejected as a bad request.
    static let macOSDeviceOS = "MacOS"
    static let desktopDeviceType = "Desktop"
}

struct GxSurveyConfiguration: Equatable, Sendable {
    var server: String
    var containerBaseURL: String
    var clientID: String
    var clientVersion: String
    var clientVariant: String
    var environment: String

    static func production(clientVersion: String) -> GxSurveyConfiguration {
        GxSurveyConfiguration(
            server: GxSurvey.productionServer,
            containerBaseURL: GxSurvey.productionContainerBaseURL,
            clientID: GxSurvey.clientID,
            clientVersion: clientVersion,
            clientVariant: "Release",
            environment: GxSurvey.productionEnvironment
        )
    }
}

/// The identity and device facts the survey endpoint carries in its query string, plus the
/// `clientParams` payload it also expects. Only the survey path uses these; they are never printed
/// into a report body.
struct GxSurveyClientContext: Equatable, Sendable {
    var userID: String
    var idpID: String
    var deviceID: String
    var deviceModel: String
    var deviceOSVersion: String
    var locale: String
    var deviceOS: String
    var deviceType: String
    var deviceMake: String
    var clientType: String
    var browserType: String
    var browserVersion: String
    var networkType: String
    var gfnSessionID: String
    var application: String
    var serverType: String
    var subscriptionSKU: String
    var datacenter: String
    var affiliate: String
    var osName: String
    var productName: String
    var productVersion: String
    var currentAppTheme: String

    init(
        userID: String,
        idpID: String,
        deviceID: String,
        deviceModel: String = "",
        deviceOSVersion: String = "",
        locale: String = "en_US",
        deviceOS: String = GxSurvey.macOSDeviceOS,
        deviceType: String = GxSurvey.desktopDeviceType,
        deviceMake: String = "Apple",
        clientType: String = "Native",
        browserType: String = "Safari",
        browserVersion: String = "",
        networkType: String = "Unknown",
        gfnSessionID: String = "",
        application: String = "GFN",
        serverType: String = "GRID",
        subscriptionSKU: String = "",
        datacenter: String = "",
        affiliate: String = "NVIDIA",
        osName: String = "MACOS",
        productName: String = "GFN",
        productVersion: String = "",
        currentAppTheme: String = "darkTheme"
    ) {
        self.userID = userID
        self.idpID = idpID
        self.deviceID = deviceID
        self.deviceModel = deviceModel
        self.deviceOSVersion = deviceOSVersion
        self.locale = locale
        self.deviceOS = deviceOS
        self.deviceType = deviceType
        self.deviceMake = deviceMake
        self.clientType = clientType
        self.browserType = browserType
        self.browserVersion = browserVersion
        self.networkType = networkType
        self.gfnSessionID = gfnSessionID
        self.application = application
        self.serverType = serverType
        self.subscriptionSKU = subscriptionSKU
        self.datacenter = datacenter
        self.affiliate = affiliate
        self.osName = osName
        self.productName = productName
        self.productVersion = productVersion
        self.currentAppTheme = currentAppTheme
    }

    /// The `/survey/v1` endpoint takes a hyphenated locale ("en-US"), while the container URL takes
    /// the identifier form ("en_US") the client forwards untouched.
    var apiLocale: String {
        locale.replacingOccurrences(of: "_", with: "-")
    }
}

/// A survey the endpoint returned: its id, what triggered it, and the container options the client
/// forwards into the survey URL.
struct GxSurveyDescriptor: Equatable, Sendable {
    let id: String
    let triggerType: String
    let name: String
    let surveySessionID: String
    let configuration: [String: String]
}

enum GxSurveyRequestFactory {
    /// The feedback survey request that backs "Send Feedback".
    static func feedbackSurveyRequest(configuration: GxSurveyConfiguration, context: GxSurveyClientContext) -> URLRequest? {
        surveyRequest(triggerType: GxSurvey.feedbackTriggerType, configuration: configuration, context: context)
    }

    static func surveyRequest(triggerType: String, configuration: GxSurveyConfiguration, context: GxSurveyClientContext) -> URLRequest? {
        guard var components = URLComponents(string: "\(configuration.server)/survey/\(GxSurvey.apiVersion)") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "clientId", value: configuration.clientID),
            URLQueryItem(name: "deviceId", value: context.deviceID),
            URLQueryItem(name: "userId", value: context.userID),
            URLQueryItem(name: "idpId", value: context.idpID),
            URLQueryItem(name: "clientVer", value: configuration.clientVersion),
            URLQueryItem(name: "clientVariant", value: configuration.clientVariant),
            URLQueryItem(name: "clientParams", value: clientParameters(context: context)),
            URLQueryItem(name: "deviceOS", value: context.deviceOS),
            URLQueryItem(name: "deviceType", value: context.deviceType),
            URLQueryItem(name: "deviceMake", value: context.deviceMake),
            URLQueryItem(name: "deviceModel", value: context.deviceModel),
            URLQueryItem(name: "deviceOSVersion", value: context.deviceOSVersion),
            URLQueryItem(name: "clientType", value: context.clientType),
            URLQueryItem(name: "browserType", value: context.browserType),
            URLQueryItem(name: "triggerType", value: triggerType),
            URLQueryItem(name: "readOnly", value: "false"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    /// The JSON the client sends as `clientParams`, in the shape the endpoint expects.
    static func clientParameters(context: GxSurveyClientContext) -> String {
        let payload: [String: String] = [
            "network": context.networkType,
            "locale": context.locale,
            "browser": context.browserType,
            "browserVersion": context.browserVersion,
            "gfnSessionId": context.gfnSessionID,
            "application": context.application,
            "serverType": context.serverType,
            "userSubscriptionLevelSKU": context.subscriptionSKU,
            "affiliate": context.affiliate,
            "datacenter": context.datacenter,
            "osName": context.osName,
            "selectedCmsId": "",
            "surveySessionId": "",
            "productName": context.productName,
            "productVersion": context.productVersion,
            "currentAppTheme": context.currentAppTheme,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Fetches the survey's first page of questions: `PUT /survey/v1?…` with an empty body, exactly
    /// as the official client does when it opens the survey.
    static func firstPageRequest(configuration: GxSurveyConfiguration, context: GxSurveyClientContext, surveyID: String) -> URLRequest? {
        feedbackRequest(configuration: configuration, context: context, surveyID: surveyID, pageID: nil, answers: nil)
    }

    /// Submits one page's answers: `PUT /survey/v1?…&pid=…` with `{"answers":[…]}`. NVIDIA returns
    /// the next page, or the terminal page when the survey is complete.
    static func submitRequest(
        configuration: GxSurveyConfiguration,
        context: GxSurveyClientContext,
        surveyID: String,
        pageID: String,
        answers: [GxSurveyAnswer]
    ) -> URLRequest? {
        feedbackRequest(configuration: configuration, context: context, surveyID: surveyID, pageID: pageID, answers: answers)
    }

    private static func feedbackRequest(
        configuration: GxSurveyConfiguration,
        context: GxSurveyClientContext,
        surveyID: String,
        pageID: String?,
        answers: [GxSurveyAnswer]?
    ) -> URLRequest? {
        guard var components = URLComponents(string: "\(configuration.server)/survey/v1") else { return nil }
        var items = [
            URLQueryItem(name: "userId", value: context.userID),
            URLQueryItem(name: "sid", value: surveyID),
            URLQueryItem(name: "isPreview", value: "false"),
            URLQueryItem(name: "locale", value: context.apiLocale),
            URLQueryItem(name: "deviceId", value: context.deviceID),
        ]
        if let pageID {
            items.insert(URLQueryItem(name: "pid", value: pageID), at: 2)
        }
        components.queryItems = items
        guard let url = components.url else { return nil }

        let body: [String: Any] = answers.map { ["answers": answerObjects($0)] } ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data
        request.timeoutInterval = 20
        return request
    }

    /// The answer objects NVIDIA's endpoint reads, with empty option lists and values omitted as
    /// the client does.
    static func answerObjects(_ answers: [GxSurveyAnswer]) -> [[String: Any]] {
        answers.map { answer in
            [
                "qid": answer.questionID,
                "oids": answer.optionIDs,
                "value": answer.value,
            ]
        }
    }
}

enum GxSurveyParser {
    static func parse(_ json: [String: Any]) -> GxSurveyDescriptor? {
        guard let id = string(json["sid"]), !id.isEmpty else { return nil }
        let debugInfo = json["debugInfo"] as? [String: Any]
        return GxSurveyDescriptor(
            id: id,
            triggerType: string(json["triggerType"]) ?? "",
            name: string(json["sname"]) ?? "",
            surveySessionID: string(debugInfo?["surveySessionId"]) ?? "",
            configuration: stringMap(json["configuration"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, raw) in dictionary {
            if let text = raw as? String {
                result[key] = text
            } else if let flag = raw as? Bool {
                result[key] = flag ? "true" : "false"
            } else if let number = raw as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }
}

/// The question kinds the survey service returns. Only the ones a native form can represent are
/// rendered natively; anything else sends the reader to the embedded survey instead of guessing.
enum GxSurveyQuestionKind: String, Sendable {
    case csat = "CSAT"
    case nps = "NPS"
    case text = "TEXT"
    case single = "SINGLE"
    case multi = "MULTI"
    case dropdown = "DDL"
    case info = "INFO"
    case unknown = "UNKNOWN"

    /// A rating row, drawn as stars. `oname` on these options is the score, the `oid` is what the
    /// answer carries.
    var isRating: Bool { self == .csat || self == .nps }

    var isNativelyRenderable: Bool {
        switch self {
        case .csat, .nps, .text, .single, .multi: return true
        case .dropdown, .info, .unknown: return false
        }
    }
}

struct GxSurveyOption: Equatable, Sendable, Identifiable {
    /// The option id the answer carries back to NVIDIA.
    let id: String
    /// The option label the reader sees.
    let name: String
}

struct GxSurveyQuestion: Equatable, Sendable, Identifiable {
    let id: String
    let text: String
    let kind: GxSurveyQuestionKind
    let isRequired: Bool
    let options: [GxSurveyOption]
}

struct GxSurveyPage: Equatable, Sendable {
    let id: String
    let questions: [GxSurveyQuestion]
    let isLastPage: Bool

    /// True when every question on the page is one the native form understands; when it is false
    /// the caller falls back to embedding NVIDIA's own survey.
    var isNativelyRenderable: Bool {
        questions.allSatisfy { $0.kind.isNativelyRenderable }
    }
}

/// One answer as NVIDIA's submit endpoint expects it: option ids for choice and rating questions,
/// free text for text questions.
struct GxSurveyAnswer: Equatable, Sendable {
    var questionID: String
    var optionIDs: [String]
    var value: String

    init(questionID: String, optionIDs: [String] = [], value: String = "") {
        self.questionID = questionID
        self.optionIDs = optionIDs
        self.value = value
    }

    var isEmpty: Bool {
        optionIDs.isEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum GxSurveyPageParser {
    static func parse(_ json: [String: Any]) -> GxSurveyPage? {
        guard let page = json["page"] as? [String: Any], let id = string(page["pid"]), !id.isEmpty else {
            return nil
        }
        let isLastPage = (json["is_last_page"] as? Bool) ?? true
        let questions = (page["questions"] as? [[String: Any]] ?? []).compactMap(question(from:))
        return GxSurveyPage(id: id, questions: questions, isLastPage: isLastPage)
    }

    private static func question(from json: [String: Any]) -> GxSurveyQuestion? {
        guard let id = string(json["qid"]), !id.isEmpty else { return nil }
        let kind = GxSurveyQuestionKind(rawValue: string(json["type"]) ?? "") ?? .unknown
        let options = (json["options"] as? [[String: Any]] ?? []).compactMap { raw -> GxSurveyOption? in
            guard let oid = string(raw["oid"]), !oid.isEmpty else { return nil }
            return GxSurveyOption(id: oid, name: string(raw["oname"]) ?? "")
        }
        return GxSurveyQuestion(
            id: id,
            text: string(json["question"]) ?? "",
            kind: kind,
            isRequired: (json["required"] as? Bool) ?? false,
            options: options
        )
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}

/// Builds the survey container URL the client loads in its embedded browser — the same URL shape
/// the official app requests.
enum GxSurveyContainerURLBuilder {
    static func url(configuration: GxSurveyConfiguration, context: GxSurveyClientContext, survey: GxSurveyDescriptor) -> URL? {
        let base = configuration.containerBaseURL.hasSuffix("/") ? configuration.containerBaseURL : configuration.containerBaseURL + "/"
        guard var components = URLComponents(string: base) else { return nil }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "userid", value: context.userID),
            URLQueryItem(name: "idpId", value: context.idpID),
            URLQueryItem(name: "locale", value: context.locale),
            URLQueryItem(name: "surveyid", value: survey.id),
            URLQueryItem(name: "clientid", value: configuration.clientID),
            URLQueryItem(name: "deviceId", value: context.deviceID),
            URLQueryItem(name: "clientVersion", value: configuration.clientVersion),
            URLQueryItem(name: "clientVariant", value: configuration.clientVariant),
            URLQueryItem(name: "env", value: configuration.environment),
            URLQueryItem(name: "surveyTimeout", value: "600"),
            URLQueryItem(name: "triggerType", value: survey.triggerType),
            URLQueryItem(name: "surveyVisited", value: "false"),
            URLQueryItem(name: "version", value: GxSurvey.containerVersion),
            URLQueryItem(name: "applicationType", value: context.application),
            URLQueryItem(name: "themeType", value: context.currentAppTheme),
        ]
        if !survey.surveySessionID.isEmpty {
            items.append(URLQueryItem(name: "surveySessionId", value: survey.surveySessionID))
        }
        for key in survey.configuration.keys.sorted() {
            items.append(URLQueryItem(name: key, value: survey.configuration[key]))
        }
        components.queryItems = items
        return components.url
    }
}
