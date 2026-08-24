import XCTest
@testable import omlxbar

/// Finding 2's other half: the per-request timeout multiplies by the size of
/// the model library, so the *whole* refresh needs its own ceiling.
@MainActor
final class DeadlineTests: XCTestCase {

    func testFastOperationReturnsItsValue() async {
        let result = await withDeadline(.seconds(2)) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testSlowOperationIsAbandoned() async {
        let start = ContinuousClock.now
        let result = await withDeadline(.milliseconds(100)) { () -> Int in
            try? await Task.sleep(for: .seconds(5))
            return 42
        }
        let elapsed = start.duration(to: .now)

        XCTAssertNil(result, "work past the deadline must not be published")
        XCTAssertLessThan(elapsed, .seconds(2), "the deadline should not have waited it out")
    }

    func testDeadlineCancelsTheWorkRatherThanLeavingItRunning() async {
        nonisolated(unsafe) var ranToCompletion = false
        _ = await withDeadline(.milliseconds(80)) { () -> Int in
            try? await Task.sleep(for: .seconds(3))
            // Cancellation makes the sleep throw, so this must not be reached
            // by way of a full three-second wait.
            if !Task.isCancelled { ranToCompletion = true }
            return 1
        }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(ranToCompletion, "the abandoned operation kept running")
    }
}

/// Finding 4's staleness half: numbers we could not refresh must stop being
/// presented as current.
@MainActor
final class StalenessTests: XCTestCase {

    override func tearDown() async throws {
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    func testAgeFormattingReadsAsAnAge() {
        let now = Date()
        XCTAssertEqual(Fmt.age(now.addingTimeInterval(-12), now: now), "12s ago")
        XCTAssertEqual(Fmt.age(now.addingTimeInterval(-125), now: now), "2m 05s ago")
    }

    func testSuccessfulReadIsNotStale() async throws {
        StubURLProtocol.install { _ in .json(Payload.activity(models: ["a"])) }
        let config = OMLXConfig(scheme: "http", host: "127.0.0.1", port: 8000, apiKey: nil)
            .validated()
        let client = OMLXClient(session: StubURLProtocol.session(), config: config)

        await client.refreshAll()

        XCTAssertFalse(client.isStale)
        XCTAssertEqual(client.state, .loadedIdle)
    }
}
