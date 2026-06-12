import Testing
import Testing
@testable import Jarvis

@Test func jarvisOperationNamesMatchVendorNames() {
    #expect(Jarvis.systemName == "Jarvis")
    #expect(Jarvis.Operation.getLoginToken.rawValue == "JARVIS_Get_Login_Token")
    #expect(Jarvis.Operation.getSessionToken.rawValue == "JARVIS_Get_Session_Token")
    #expect(Jarvis.oauthLoggerName == "jarvis/o-auth")
}
