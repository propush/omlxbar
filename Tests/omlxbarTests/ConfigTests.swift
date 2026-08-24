import XCTest
@testable import omlxbar

/// Finding 1: the API key travels on every request, so a cleartext remote
/// target is credential disclosure. These pin the rule that permits it for
/// loopback and nowhere else.
final class ConfigTests: XCTestCase {

    private func resolve(_ env: [String: String], settings: [String: Any]? = nil) -> OMLXConfig {
        OMLXConfig.resolve(settings: settings, environment: env)
    }

    func testLoopbackKeepsPlainHTTP() {
        let config = resolve([:])
        XCTAssertNil(config.rejection)
        XCTAssertEqual(config.scheme, "http")
        XCTAssertEqual(config.baseURL?.absoluteString, "http://127.0.0.1:8000")
    }

    func testCleartextToRemoteHostIsRefused() {
        let config = resolve(["OMLXBAR_URL": "http://example.com:8000"])
        XCTAssertNotNil(config.rejection, "http:// to a non-loopback host must be refused")
        XCTAssertNil(config.baseURL, "a refused target must not be reachable")
        XCTAssertTrue(config.rejection!.contains("example.com"))
    }

    func testRefusalDoesNotSilentlyFallBackToLoopback() {
        let config = resolve(["OMLXBAR_URL": "http://example.com:8000"])
        // Quietly talking to some *other* server would be worse than refusing:
        // the numbers would look real and belong to the wrong machine.
        XCTAssertNil(config.baseURL)
        XCTAssertEqual(config.host, "example.com")
    }

    func testHTTPSToRemoteHostIsAccepted() {
        let config = resolve(["OMLXBAR_URL": "https://example.com:8443"])
        XCTAssertNil(config.rejection)
        XCTAssertEqual(config.baseURL?.absoluteString, "https://example.com:8443")
    }

    func testHTTPSDefaultsToPort443WhenOmitted() {
        let config = resolve(["OMLXBAR_URL": "https://example.com"])
        XCTAssertEqual(config.port, 443)
        XCTAssertNil(config.rejection)
    }

    func testBareRemoteHostOverrideIsUpgradedNotLeaked() {
        // OMLXBAR_HOST carries no scheme. Upgrading is safe; defaulting to
        // cleartext would put the key on the wire.
        let config = resolve(["OMLXBAR_HOST": "example.com"])
        XCTAssertEqual(config.scheme, "https")
        XCTAssertNil(config.rejection)
    }

    func testBareLoopbackHostOverrideStaysHTTP() {
        let config = resolve(["OMLXBAR_HOST": "127.0.0.1", "OMLXBAR_PORT": "9000"])
        XCTAssertEqual(config.scheme, "http")
        XCTAssertEqual(config.port, 9000)
        XCTAssertNil(config.rejection)
    }

    func testMalformedURLIsRefusedRatherThanIgnored() {
        let config = resolve(["OMLXBAR_URL": "ftp://example.com"])
        XCTAssertNotNil(config.rejection)
        XCTAssertNil(config.baseURL)
    }

    func testWildcardBindAddressIsTreatedAsLoopback() {
        let config = resolve([:], settings: ["server": ["host": "0.0.0.0", "port": 8000]])
        XCTAssertTrue(config.isLoopback)
        XCTAssertNil(config.rejection)
        XCTAssertEqual(config.baseURL?.absoluteString, "http://127.0.0.1:8000")
    }

    func testLoopbackRecognisesTheWholeBlock() {
        XCTAssertTrue(OMLXConfig.isLoopback("127.0.0.1"))
        XCTAssertTrue(OMLXConfig.isLoopback("127.1.2.3"))
        XCTAssertTrue(OMLXConfig.isLoopback("localhost"))
        XCTAssertTrue(OMLXConfig.isLoopback("::1"))
        XCTAssertFalse(OMLXConfig.isLoopback("example.com"))
        XCTAssertFalse(OMLXConfig.isLoopback("10.0.0.5"))
        XCTAssertFalse(OMLXConfig.isLoopback("127notanip.example.com"))
    }

    func testOutOfRangePortIsRefused() {
        let config = resolve(["OMLXBAR_PORT": "70000"])
        XCTAssertNotNil(config.rejection)
        XCTAssertNil(config.baseURL)
    }
}
