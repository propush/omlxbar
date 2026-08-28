import XCTest
@testable import omlxbar

final class MemoryPresentationTests: XCTestCase {
    private let gib = 1_073_741_824

    private func activity(
        modelUsed: Int = 12 * 1_073_741_824,
        ceiling: Int = 64 * 1_073_741_824,
        processUsed: Int = 32 * 1_073_741_824,
        soft: Int = 48 * 1_073_741_824,
        hard: Int = 56 * 1_073_741_824,
        telemetryEnabled: Bool = true
    ) -> ActiveModelsDTO {
        var activity = ActiveModelsDTO()
        activity.modelMemoryUsed = modelUsed
        activity.modelMemoryMax = ceiling
        activity.memoryPressure.enabled = telemetryEnabled
        activity.memoryPressure.currentBytes = processUsed
        activity.memoryPressure.softBytes = soft
        activity.memoryPressure.hardBytes = hard
        return activity
    }

    func testGuardedModeUsesProcessMemoryAndGuardWatermarks() {
        let presentation = MemoryPresentation(
            activity: activity(), deviceMemoryGB: 128, guardEnabled: true
        )

        XCTAssertEqual(presentation.mode, .guarded)
        XCTAssertEqual(presentation.title, "Process Memory")
        XCTAssertEqual(presentation.usedBytes, 32 * gib)
        XCTAssertEqual(presentation.softBytes, 48 * gib)
        XCTAssertEqual(presentation.hardBytes, 56 * gib)
        XCTAssertEqual(presentation.barLimitBytes, 56 * gib)
        XCTAssertEqual(presentation.fraction, 32.0 / 56.0, accuracy: 0.0001)
        XCTAssertEqual(presentation.softMarkerFraction, 48.0 / 56.0, accuracy: 0.0001)
        XCTAssertNil(presentation.statusText)
        XCTAssertEqual(
            presentation.valueText,
            "32.0 GB / 48.0 GB soft / 56.0 GB hard"
        )
        XCTAssertEqual(
            presentation.diagnosticSummary,
            "process memory 32.0 GB / 48.0 GB soft / 56.0 GB hard"
        )
    }

    func testGuardedModeFallsBackWhenProcessTelemetryIsMissing() {
        let presentation = MemoryPresentation(
            activity: activity(processUsed: 0), deviceMemoryGB: 128, guardEnabled: true
        )

        XCTAssertEqual(presentation.usedBytes, 12 * gib)
        XCTAssertEqual(presentation.fraction, 12.0 / 56.0, accuracy: 0.0001)
    }

    func testGuardedModeDoesNotDisguiseMissingHardWatermarkAsDisabled() {
        let presentation = MemoryPresentation(
            activity: activity(hard: 0), deviceMemoryGB: 128, guardEnabled: true
        )

        XCTAssertEqual(presentation.mode, .guarded)
        XCTAssertEqual(presentation.usedBytes, 32 * gib)
        XCTAssertEqual(presentation.hardBytes, 0)
        XCTAssertEqual(presentation.barLimitBytes, 0)
        XCTAssertEqual(presentation.fraction, 0)
        XCTAssertEqual(presentation.softMarkerFraction, 0)
        XCTAssertEqual(presentation.statusText, "Guard limit unavailable")
        XCTAssertEqual(
            presentation.diagnosticSummary,
            "process memory 32 GB used, guard limit unavailable"
        )
    }

    func testDisabledGuardPreservesModelMemoryAgainstInstalledRAM() {
        let presentation = MemoryPresentation(
            activity: activity(), deviceMemoryGB: 128, guardEnabled: false
        )

        XCTAssertEqual(presentation.mode, .unguarded)
        XCTAssertEqual(presentation.title, "Model Memory")
        XCTAssertEqual(presentation.usedBytes, 12 * gib)
        XCTAssertEqual(presentation.softBytes, 0)
        XCTAssertEqual(presentation.hardBytes, 0)
        XCTAssertEqual(presentation.barLimitBytes, 128 * gib)
        XCTAssertEqual(presentation.fraction, 12.0 / 128.0, accuracy: 0.0001)
        XCTAssertEqual(presentation.softMarkerFraction, 0)
        XCTAssertEqual(presentation.statusText, "Enforcer disabled")
        XCTAssertEqual(
            presentation.diagnosticSummary,
            "model memory 12 GB used, ceiling none (enforcer disabled)"
        )
    }

    func testMissingGuardSettingUsesLiveGuardTelemetryWhenAvailable() {
        let presentation = MemoryPresentation(
            activity: activity(), deviceMemoryGB: 128, guardEnabled: nil
        )

        XCTAssertEqual(presentation.mode, .guarded)
        XCTAssertEqual(presentation.usedBytes, 32 * gib)
    }

    func testMissingGuardSettingWithoutLiveWatermarksUsesLegacyMode() {
        let presentation = MemoryPresentation(
            activity: activity(hard: 0, telemetryEnabled: false),
            deviceMemoryGB: 128,
            guardEnabled: nil
        )

        XCTAssertEqual(presentation.mode, .unguarded)
        XCTAssertEqual(presentation.usedBytes, 12 * gib)
    }

    func testInvalidValuesNormalizeAndOverLimitUsageClamps() {
        let invalid = MemoryPresentation(
            activity: activity(
                modelUsed: -1, ceiling: -2, processUsed: -3, soft: -4, hard: -5
            ),
            deviceMemoryGB: -4,
            guardEnabled: true
        )
        XCTAssertEqual(invalid.usedBytes, 0)
        XCTAssertEqual(invalid.softBytes, 0)
        XCTAssertEqual(invalid.hardBytes, 0)
        XCTAssertEqual(invalid.fraction, 0)

        let overLimit = MemoryPresentation(
            activity: activity(processUsed: 80 * gib),
            deviceMemoryGB: 128,
            guardEnabled: true
        )
        XCTAssertEqual(overLimit.fraction, 1)
    }

    func testGuardedFormattingMatchesOMLXDashboard() {
        let mib = 1_048_576
        let presentation = MemoryPresentation(
            activity: activity(
                processUsed: 792 * mib,
                soft: Int(25.4 * Double(gib)),
                hard: Int(28.4 * Double(gib))
            ),
            deviceMemoryGB: 48,
            guardEnabled: true
        )

        XCTAssertEqual(presentation.valueText, "792 MB / 25.4 GB soft / 28.4 GB hard")
    }

    func testBarLevelUsesOMLXUtilizationThresholds() {
        XCTAssertEqual(MemoryBarLevel(fraction: 0.59), .green)
        XCTAssertEqual(MemoryBarLevel(fraction: 0.60), .yellow)
        XCTAssertEqual(MemoryBarLevel(fraction: 0.70), .amber)
        XCTAssertEqual(MemoryBarLevel(fraction: 0.80), .orange)
        XCTAssertEqual(MemoryBarLevel(fraction: 0.90), .red)
    }
}
