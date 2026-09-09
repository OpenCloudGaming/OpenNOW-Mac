import Foundation
import Testing
@testable import OpenNOW

/// The redaction pass skips rules whose marker is absent from the message. That is only sound if the
/// gated result is byte-for-byte what running every rule produces — a missed rule is a leaked
/// credential, not a slow log line. These tests hold the gated path against the unconditional one.
private func expectEquivalent(_ message: String, _ comment: Comment? = nil) {
    #expect(OPNSentry.sanitizedMessage(message) == OPNSentry.exhaustivelySanitizedMessage(message), comment ?? "\(message)")
}

@Test func gatedRedactionMatchesTheExhaustivePassOnKnownVectors() {
    let vectors = [
        "email=user@example.com phone=+1 555 123 4567 token=abc.def.ghi ipv4=192.168.1.24",
        "ipv6=2600:1702:7b40:6190:69ea:cb80:cf15:6289 host=seat.example",
        "GET https://login.example/logout?id_token_hint=eyJhbGciOi.eyJzdWIiOiJ4.signature&state=1",
        "authorization Bearer abcdefghijklmnopqrstuvwx",
        "authorization Basic dXNlcjpwYXNzd29yZA==",
        "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:encryptionKey=Zm9vYmFyYmF6",
        "apikey: sk-01234567890 password:hunter2 pwd = swordfish",
        "NVST counters auth=51234 fec=12 dropped=0 frames=7211 decoded=7210 rtt=5.4ms ssrc=0x1a2b3c4d",
        "NVST hud rtt=5.1ms jitter=1.2ms decodedRes=5120x2160 gameFps=119.4",
        "plain message with nothing to redact at all",
        "",
        "&key=550e8400-e29b-41d4-a716-446655440000 ::1",
        "secret",
        "?token=",
        "1234.5.6.7 and 1.2.3.4567 and 1.2.3.4",
        "Bearer\nabcdefghij",
        "\u{212A}elvin token=abc",
        "long\u{17F} secret=abc",
        "İstanbul password=abc",
        "日本語 token=abc ip=10.0.0.1",
        "é token=abc",
    ]
    for vector in vectors { expectEquivalent(vector) }
}

/// The templates themselves contain "secret", so a rewrite by one rule can create the marker a later
/// rule needs. The gate stops applying after the first rewrite; this is the case that proves it must.
@Test func gatedRedactionKeepsTheCascadeBetweenRules() {
    let cascading = "&key=550e8400-e29b-41d4-a716-446655440000 ::1"
    let sanitized = OPNSentry.sanitizedMessage(cascading)

    #expect(sanitized == OPNSentry.exhaustivelySanitizedMessage(cascading))
    #expect(!sanitized.contains("550e8400"))
}

/// Non-ASCII disables the gate entirely, because ICU's caseless matching folds characters an ASCII
/// scan cannot see. Deterministic generator, so a failure is reproducible from the seed.
@Test func gatedRedactionMatchesTheExhaustivePassOnGeneratedInput() {
    let alphabet = Array("abcdefgHIJKtoken=secret:pwd?&.:/0123456789 \n\tBearer eyJ\u{212A}\u{17F}é")
    var generator = SystemRandomNumberGenerator()
    var seeds: [String] = []
    for _ in 0..<4000 {
        let length = Int.random(in: 0...80, using: &generator)
        seeds.append(String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "a" }))
    }
    for seed in seeds { expectEquivalent(seed) }
}

/// The gate must never be the reason something stays visible: whatever the rules redact today, the
/// gated path still redacts.
@Test func gatedRedactionStillRemovesEveryCredentialShape() {
    let sanitized = OPNSentry.sanitizedMessage(
        "url=https://x/y?access_token=abc123 Bearer abcdefghijklmnop password=hunter2 ip=192.168.1.24"
    )

    #expect(!sanitized.contains("abc123"))
    #expect(!sanitized.contains("abcdefghijklmnop"))
    #expect(!sanitized.contains("hunter2"))
    #expect(!sanitized.contains("192.168.1.24"))
}

/// The upload path adds location rules and runs over a whole log at once. Same gate, same
/// obligation: byte-for-byte what running every rule produces.
@Test func gatedUploadRedactionMatchesTheExhaustivePass() {
    let vectors = [
        "region=eu-west-2 city=London timezone=Europe/London lat=51.5 lon=-0.12",
        "seat host=eu-london-1.cloudmatch.example.com rtt=12ms",
        "ipv6=2600:1702:7b40:6190:69ea:cb80:cf15:6289",
        "NVST counters auth=51234 frames=7211 rtt=5.4ms",
        "no location data here at all",
        "",
        "日本語 city=Tokyo",
        "COUNTRY: Japan\nLatitude: 35.6",
    ]
    for vector in vectors {
        #expect(OPNSentry.sanitizedUploadLog(vector) == OPNSentry.exhaustivelySanitizedUploadLog(vector), "\(vector)")
    }
}

@Test func gatedUploadRedactionStillRemovesLocation() {
    let sanitized = OPNSentry.sanitizedUploadLog("city=London lat=51.5 host=eu-west.cloudmatch.example ip=192.168.1.24")

    #expect(!sanitized.contains("London"))
    #expect(!sanitized.contains("51.5"))
    #expect(!sanitized.contains("cloudmatch.example"))
    #expect(!sanitized.contains("192.168.1.24"))
}
