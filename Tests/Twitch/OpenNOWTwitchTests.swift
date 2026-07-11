import Foundation
import Testing
@testable import OpenNOW

@Test func ircParserDecodesPrivmsg() throws {
    let line = "@badge-info=;badges=;color=#9146FF;display-name=Jayian;id=abc :jayian!jayian@jayian.tmi.twitch.tv PRIVMSG #jayian :hello stream"
    let message = try #require(TwitchIRCParser.parseMessage(line))
    #expect(message.id == "abc")
    #expect(message.author == "jayian")
    #expect(message.displayName == "Jayian")
    #expect(message.text == "hello stream")
}

@Test func preferencesCodableRoundTrip() throws {
    var preferences = TwitchBroadcastPreferences()
    preferences.resolution = .p936
    preferences.videoBitrateKbps = 7_500
    let data = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(TwitchBroadcastPreferences.self, from: data)
    #expect(decoded.resolution == .p936)
    #expect(decoded.videoBitrateKbps == 7_500)
}
