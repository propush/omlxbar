import XCTest
@testable import omlxbar

/// Findings 2–5: what the client does when the server is slow, when responses
/// arrive out of order, when the payload stops making sense, and when there is
/// nothing trustworthy left to show.
@MainActor
final class OMLXClientTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        Diagnostics.reset()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omlxbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    /// A client pointed at loopback, with no stats file on disk unless a test
    /// writes one.
    private func makeClient(
        host: String = "127.0.0.1", scheme: String = "http", statsFile: String? = nil
    ) throws -> OMLXClient {
        let statsPath = tempDir.appendingPathComponent("stats.json")
        if let statsFile { try Data(statsFile.utf8).write(to: statsPath) }
        let config = OMLXConfig(scheme: scheme, host: host, port: 8000, apiKey: "k").validated()
        let client = OMLXClient(
            session: StubURLProtocol.session(), config: config, statsPath: statsPath
        )
        client.modelFilter = nil
        return client
    }

    // MARK: Finding 4 — contract drift must not read as healthy

    func testMissingActivityEnvelopeIsIncompatibleNotIdle() async throws {
        StubURLProtocol.install { _ in .json(#"{"server":"ok","models_active":[]}"#) }
        let client = try makeClient()

        await client.refreshAll()

        // The old behaviour defaulted the envelope to empty and painted a green
        // "No model" dot for a server it could no longer read.
        XCTAssertEqual(client.state, .incompatible)
        XCTAssertNotEqual(client.state, .idleNoModel)
        XCTAssertTrue(client.state.isUncertain)
        XCTAssertFalse(client.state.isFilled, "an unreadable server must never look filled-in")
    }

    func testHTMLErrorPageIsIncompatibleNotIdle() async throws {
        StubURLProtocol.install { _ in .html("<html><body>502 Bad Gateway</body></html>") }
        let client = try makeClient()

        await client.refreshAll()

        XCTAssertEqual(client.state, .incompatible)
    }

    func testWellFormedActivityStillDecodes() async throws {
        StubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/activity") {
                return .json(Payload.activity(models: ["a"], activeRequests: 2))
            }
            return .json(Payload.stats(requests: 5))
        }
        let client = try makeClient()

        await client.refreshAll()

        XCTAssertEqual(client.state, .active)
        XCTAssertFalse(client.isStale)
        XCTAssertNotNil(client.lastSuccess)
    }

    func testIncompatibleResponseMarksWhatIsOnScreenStale() async throws {
        StubURLProtocol.install { _ in .json(#"{"nope":true}"#) }
        let client = try makeClient()

        await client.refreshAll()

        XCTAssertTrue(client.isStale, "we cannot vouch for numbers we could not refresh")
    }

    // MARK: Finding 3 — no mixed or superseded snapshots

    func testSupersededScopeRefreshDoesNotPublish() async throws {
        StubURLProtocol.install { request in
            let query = request.url?.query ?? ""
            if request.url?.path.hasSuffix("/activity") == true {
                return .json(Payload.activity())
            }
            if query.contains("scope=alltime") {
                // The slow, older request. It must lose.
                return StubReply(body: Data(Payload.stats(requests: 999).utf8), delay: 0.4)
            }
            return .json(Payload.stats(requests: 1))
        }
        let client = try makeClient()

        client.scope = .allTime
        // Superseded before the all-time response can land.
        client.scope = .session
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(client.scope, .session)
        XCTAssertEqual(
            client.totals.totalRequests, 1,
            "a slower older refresh must not overwrite the newer one it lost to"
        )
    }

    func testPerModelRequestsUseTheScopeCapturedAtRefreshStart() async throws {
        StubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/activity") { return .json(Payload.activity()) }
            if path.hasSuffix("/models") { return .json(Payload.models(["m1", "m2", "m3"])) }
            return .json(Payload.stats(requests: 7))
        }
        let client = try makeClient()
        client.scope = .allTime

        await client.refreshAll()

        let perModel = StubURLProtocol.paths(containing: "model=")
        XCTAssertFalse(perModel.isEmpty, "the fan-out should have run")
        for path in perModel {
            XCTAssertTrue(
                path.contains("scope=alltime"),
                "per-model request used a different scope than the refresh started with: \(path)"
            )
        }
    }

    // MARK: Finding 2 — the fan-out must stay bounded

    func testFanOutConcurrencyIsCapped() async throws {
        let ids = (1...12).map { "model-\($0)" }
        StubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/activity") { return .json(Payload.activity()) }
            if path.hasSuffix("/models") { return .json(Payload.models(ids)) }
            // Slow enough that unbounded parallelism would overlap visibly.
            return StubReply(body: Data(Payload.stats(requests: 3).utf8), delay: 0.05)
        }
        let client = try makeClient()

        await client.refreshAll()

        XCTAssertLessThanOrEqual(
            StubURLProtocol.peakConcurrency, OMLXClient.maxConcurrentStatsRequests,
            "the fan-out exceeded its concurrency cap"
        )
        XCTAssertEqual(client.perModel.count, ids.count, "every model should still get stats")
    }

    func testPartialPerModelFailurePreservesPreviousRows() async throws {
        nonisolated(unsafe) var failSecondModel = false
        StubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.hasSuffix("/activity") { return .json(Payload.activity()) }
            if path.hasSuffix("/models") { return .json(Payload.models(["m1", "m2"])) }
            if query.contains("model=m2") {
                if failSecondModel { return .json(#"{"detail":"boom"}"#, status: 500) }
                return .json(Payload.stats(requests: 22))
            }
            return .json(Payload.stats(requests: 11))
        }
        let client = try makeClient()

        await client.refreshAll()
        XCTAssertEqual(client.perModel["m2"]?.totalRequests, 22)

        failSecondModel = true
        await client.refreshAll()

        // Replacing the map wholesale used to make the row vanish from the
        // overlay the moment one request failed.
        XCTAssertEqual(
            client.perModel["m2"]?.totalRequests, 22,
            "a failed per-model request must not erase that model's last known numbers"
        )
        XCTAssertEqual(client.perModel["m1"]?.totalRequests, 11)
    }

    func testModelsNoLongerReportedAreDropped() async throws {
        nonisolated(unsafe) var secondModelPresent = true
        StubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/activity") { return .json(Payload.activity()) }
            if path.hasSuffix("/models") {
                return .json(Payload.models(secondModelPresent ? ["m1", "m2"] : ["m1"]))
            }
            return .json(Payload.stats(requests: 4))
        }
        let client = try makeClient()

        await client.refreshAll()
        XCTAssertNotNil(client.perModel["m2"])

        secondModelPresent = false
        await client.refreshAll()

        XCTAssertNil(client.perModel["m2"], "a model the server dropped should not linger")
    }

    // MARK: Finding 5 — offline numbers must be attributable

    func testOfflineFallbackIsSkippedForARemoteTarget() async throws {
        StubURLProtocol.install { _ in .json(#"{"detail":"down"}"#, status: 503) }
        // A real stats.json exists on this machine — and belongs to it.
        let client = try makeClient(
            host: "example.com", scheme: "https",
            statsFile: #"{"total_requests":4242,"total_prompt_tokens":1000}"#
        )

        await client.refreshAll()

        XCTAssertFalse(
            client.usingOfflineStats,
            "this Mac's stats file is not the remote server's history"
        )
        XCTAssertTrue(client.statsUnavailable)
        XCTAssertEqual(client.totals.totalRequests, 0)
    }

    func testOfflineFallbackIsUsedForLoopbackAndDated() async throws {
        StubURLProtocol.install { _ in .json(#"{"detail":"down"}"#, status: 503) }
        let client = try makeClient(
            statsFile: #"{"total_requests":4242,"total_prompt_tokens":1000}"#
        )

        await client.refreshAll()

        XCTAssertTrue(client.usingOfflineStats)
        XCTAssertFalse(client.statsUnavailable)
        XCTAssertEqual(client.totals.totalRequests, 4242)
        XCTAssertNotNil(
            client.offlineStatsCapturedAt,
            "the overlay must be able to say how old the disk numbers are"
        )
    }

    func testUnreadableStatsFileClearsRatherThanKeepsStaleTotals() async throws {
        nonisolated(unsafe) var serverUp = true
        StubURLProtocol.install { request in
            guard serverUp else { return .json(#"{"detail":"down"}"#, status: 503) }
            let path = request.url?.path ?? ""
            if path.hasSuffix("/activity") { return .json(Payload.activity()) }
            return .json(Payload.stats(requests: 77))
        }
        // No stats file written: recovery has nothing to offer.
        let client = try makeClient()

        await client.refreshAll()
        XCTAssertEqual(client.totals.totalRequests, 77)

        serverUp = false
        await client.refreshAll()

        XCTAssertTrue(client.statsUnavailable)
        XCTAssertFalse(client.usingOfflineStats)
        XCTAssertEqual(
            client.totals.totalRequests, 0,
            "live session totals must not be relabelled as recovered history"
        )
    }

    // MARK: Refused target

    func testRefusedTargetNeverSendsARequest() async throws {
        StubURLProtocol.install { _ in .json(Payload.activity()) }
        let config = OMLXConfig(scheme: "http", host: "example.com", port: 8000, apiKey: "secret")
            .validated()
        let client = OMLXClient(session: StubURLProtocol.session(), config: config)

        await client.refreshAll()

        XCTAssertEqual(client.state, .misconfigured)
        XCTAssertTrue(
            StubURLProtocol.log.isEmpty,
            "a refused target must not put the API key on the wire: \(StubURLProtocol.log)"
        )
    }
}
