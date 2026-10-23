import XCTest
@testable import KeelCore

final class RedisURLTests: XCTestCase {
    func testParsesFullURL() throws {
        let url = try RedisURL(parsing: "rediss://app:p%40ss@cache.internal:6380/2")
        XCTAssertEqual(url, RedisURL(tls: true, username: "app", password: Data("p@ss".utf8), host: "cache.internal", port: 6380, database: 2))

        // AC1: filling the form turns TLS on and sets every connection field; unrelated settings are kept.
        var form = ConnectionSettings(name: "", label: .blue, readOnly: true, separator: "::")
        form = url.applied(to: form)
        XCTAssertNotNil(form.tls); XCTAssertEqual(form.username, "app"); XCTAssertEqual(form.host, "cache.internal")
        XCTAssertEqual(form.port, 6380); XCTAssertEqual(form.database, 2)
        XCTAssertEqual(form.name, "cache.internal", "a blank name takes the host")
        XCTAssertEqual(form.label, .blue); XCTAssertTrue(form.readOnly); XCTAssertEqual(form.separator, "::")
        XCTAssertNoThrow(try form.validated())

        // Defaults: no port, no db, no userinfo; scheme is case-insensitive; surrounding whitespace from a paste is trimmed.
        XCTAssertEqual(try RedisURL(parsing: "  REDIS://localhost\n"), RedisURL(host: "localhost"))
        XCTAssertEqual(try RedisURL(parsing: "redis://10.0.0.5/"), RedisURL(host: "10.0.0.5"))
        XCTAssertEqual(try RedisURL(parsing: "redis://ops@h"), RedisURL(username: "ops", host: "h"))
        // An unencoded "@" in a password splits at the last "@".
        XCTAssertEqual(try RedisURL(parsing: "redis://u:a@b@h:1/0").password, Data("a@b".utf8))
        // Percent-decoding yields bytes, even ones that are not UTF-8.
        XCTAssertEqual(try RedisURL(parsing: "redis://:%FF%00x@h").password, Data([0xFF, 0x00, 0x78]))

        // redis:// turns TLS off but a rediss:// paste keeps the form's TLS server name and CA.
        let tlsForm = ConnectionSettings(name: "x", tls: TLSSettings(serverName: "sni.internal", caFile: "/ca.pem"))
        XCTAssertNil(try RedisURL(parsing: "redis://h").applied(to: tlsForm).tls)
        XCTAssertEqual(try RedisURL(parsing: "rediss://h").applied(to: tlsForm).tls, tlsForm.tls)
        XCTAssertEqual(try RedisURL(parsing: "redis://h").applied(to: tlsForm).name, "x", "a name already typed is kept")
        XCTAssertTrue(RedisURL.isCandidate(" Rediss://x")); XCTAssertFalse(RedisURL.isCandidate("http://x"))
    }

    func testParsesIPv6Host() throws {
        XCTAssertEqual(try RedisURL(parsing: "redis://[::1]:6390/3"), RedisURL(host: "::1", port: 6390, database: 3))
        XCTAssertEqual(try RedisURL(parsing: "rediss://u@[2001:db8::7]"), RedisURL(tls: true, username: "u", host: "2001:db8::7"))
        // RFC 6874 zone ID.
        XCTAssertEqual(try RedisURL(parsing: "redis://[fe80::1%25en0]:7000").host, "fe80::1%en0")
        XCTAssertEqual(try RedisURL(parsing: "redis://[::ffff:10.0.0.1]").host, "::ffff:10.0.0.1")
        let form = try RedisURL(parsing: "redis://[::1]:6390").applied(to: ConnectionSettings(name: "v6"))
        XCTAssertEqual(form.host, "::1", "stored bare, as NWEndpoint expects"); XCTAssertNoThrow(try form.validated())
    }

    func testPasswordOnlyUserinfo() throws {
        let url = try RedisURL(parsing: "redis://:s3cret@cache:6379")
        XCTAssertNil(url.username); XCTAssertEqual(url.password, Data("s3cret".utf8))
        XCTAssertNil(url.applied(to: ConnectionSettings(name: "a", username: "old")).username, "a password-only URL clears the ACL user")
        // Empty parts are absent, not empty strings.
        XCTAssertEqual(try RedisURL(parsing: "redis://:@h"), RedisURL(host: "h"))
        XCTAssertEqual(try RedisURL(parsing: "redis://app:@h"), RedisURL(username: "app", host: "h"))
        XCTAssertEqual(try RedisURL(parsing: "redis://@h"), RedisURL(host: "h"))
    }

    func testReportsIgnoredQueryParameters() throws {
        let url = try RedisURL(parsing: "rediss://h:6380/1?ssl_cert_reqs=none&timeout=5&ssl_cert_reqs=x&flag&a%20b=1&&=v")
        XCTAssertEqual(url.ignoredQueryParameters, ["ssl_cert_reqs", "timeout", "flag", "a b"])
        // Ignored means not applied: the rest of the URL is parsed as if the query were absent.
        XCTAssertEqual(url, RedisURL(tls: true, host: "h", port: 6380, database: 1, ignoredQueryParameters: url.ignoredQueryParameters))
        XCTAssertEqual(try RedisURL(parsing: "redis://h?").ignoredQueryParameters, [])
        XCTAssertEqual(try RedisURL(parsing: "redis://h?db=4").database, 0, "a db query parameter is listed, never applied")
    }

    func testRejectsMalformedURLs() {
        let cases: [(String, RedisURLError)] = [
            ("", .notAURL), ("cache.internal:6379", .notAURL), ("redis:/h", .notAURL), ("redis://h /0", .notAURL),
            ("redis://h\n:1", .notAURL), ("redis://h#frag", .notAURL), ("redis://" + String(repeating: "a", count: 5000), .notAURL),
            ("http://h", .unsupportedScheme), ("unix:///tmp/redis.sock", .unsupportedScheme), ("://h", .unsupportedScheme),
            ("redis://:p%4@h", .invalidEncoding), ("redis://:p%zz@h", .invalidEncoding), ("redis://h?%G1=1", .invalidEncoding),
            ("redis://a%0Ab@h", .invalidUserinfo), ("redis://%FF@h", .invalidUserinfo), ("redis://a%20b@h", .invalidUserinfo),
            ("redis://", .invalidHost), ("redis://u@", .invalidHost), ("redis://:6379", .invalidHost), ("redis://::1", .invalidHost),
            ("redis://[::1", .invalidHost), ("redis://[::1]x", .invalidHost), ("redis://[nothex]", .invalidHost), ("redis://-oProxy=x", .invalidHost),
            ("redis://h%2Fx", .invalidHost), ("redis://[]:1", .invalidHost), ("redis://[:::]", .invalidHost), ("redis://[1::2::3]", .invalidHost),
            ("redis://[fe80::1%25]", .invalidHost), ("redis://[::1%25%5D]", .invalidHost), ("redis://%5Bab%5D", .invalidHost), ("redis://h%25x", .invalidHost),
            ("redis://h]x", .invalidHost),
            ("redis://h:", .invalidPort), ("redis://h:0", .invalidPort), ("redis://h:65536", .invalidPort), ("redis://h:-1", .invalidPort),
            ("redis://h:63a", .invalidPort), ("redis://h:٦٣٧٩", .invalidPort), ("redis://[::1]:", .invalidPort),
            ("redis://h/x", .invalidDatabase), ("redis://h/65536", .invalidDatabase), ("redis://h/1/2", .invalidDatabase), ("redis://h/-1", .invalidDatabase)
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try RedisURL(parsing: text), text.debugDescription) { XCTAssertEqual($0 as? RedisURLError, expected, text.debugDescription) }
        }
        // AC4: a failed parse yields no value, so the form keeps its fields; every error has an inline message.
        let form = ConnectionSettings(name: "keep", host: "old", port: 7000, username: "u", database: 3)
        let after = (try? RedisURL(parsing: "redis://h:0"))?.applied(to: form) ?? form
        XCTAssertEqual(after, form)
        for error in Set(cases.map { $0.1.message }) { XCTAssertFalse(error.isEmpty) }
    }

    func testCopyAsURLOmitsPassword() throws {
        let settings = ConnectionSettings(name: "p", host: "cache.internal", port: 6380, username: "app", database: 2, tls: TLSSettings(serverName: "sni"))
        var url = RedisURL(settings: settings)
        XCTAssertEqual(url.string, "rediss://app@cache.internal:6380/2")
        url.password = Data("p@ss".utf8); url.ignoredQueryParameters = ["timeout"]
        XCTAssertEqual(url.string, "rediss://app@cache.internal:6380/2", "the password is never copied, even when set")
        XCTAssertEqual(RedisURL(settings: ConnectionSettings(name: "l")).string, "redis://127.0.0.1:6379/0")

        // Encoded where needed, and the copy parses back to the same connection fields.
        let tricky = ConnectionSettings(name: "t", host: "fe80::1%en0", port: 7000, username: "ops:a@b")
        let copied = RedisURL(settings: tricky).string
        XCTAssertEqual(copied, "redis://ops%3Aa%40b@[fe80::1%25en0]:7000/0")
        XCTAssertEqual(try RedisURL(parsing: copied).applied(to: tricky), tricky)
        XCTAssertEqual(RedisURL(settings: ConnectionSettings(name: "b", host: "[::1]")).string, "redis://[::1]:6379/0")
    }

    /// AC3: saving a pasted URL sends the password to the Keychain; `connections.json` holds neither it nor the URL.
    func testPastedURLIsNeverPersisted() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        let store = await fixture.store()
        let text = "rediss://app:Url-Secret-42@cache.internal:6380/2?timeout=5"
        let url = try RedisURL(parsing: text)
        let profile = try await store.create(url.applied(to: ConnectionSettings(name: "")), password: url.password)
        XCTAssertTrue(profile.hasPassword)
        XCTAssertEqual(fixture.secrets.item(.password, profile.id), Data("Url-Secret-42".utf8))
        let bytes = try Data(contentsOf: fixture.fileURL)
        for needle in ["Url-Secret-42", "rediss://", "timeout"] { XCTAssertNil(bytes.range(of: Data(needle.utf8)), needle) }
    }
}
