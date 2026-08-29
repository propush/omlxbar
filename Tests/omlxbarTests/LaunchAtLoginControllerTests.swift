import ServiceManagement
import XCTest
@testable import omlxbar

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.pushkin.omlxbar.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMigrationPreservesEnabledRegistrationAndRefreshesCurrentBuild() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = makeController(service: service, build: "2.0.0")

        controller.reconcileInstalledBuild()

        XCTAssertTrue(controller.desiredEnabled)
        XCTAssertEqual(service.calls, [.unregister, .register])
        XCTAssertEqual(defaults.string(forKey: LaunchAtLoginController.registeredBuildKey), "2.0.0")
    }

    func testMigrationKeepsUnregisteredAppOptedOut() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = makeController(service: service)

        controller.reconcileInstalledBuild()

        XCTAssertFalse(controller.desiredEnabled)
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testUnchangedRegisteredBuildIsNoOp() {
        defaults.set(true, forKey: LaunchAtLoginController.desiredKey)
        defaults.set("2.0.0", forKey: LaunchAtLoginController.registeredBuildKey)
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = makeController(service: service, build: "2.0.0")

        controller.reconcileInstalledBuild()

        XCTAssertTrue(service.calls.isEmpty)
    }

    func testChangedBuildIsUnregisteredBeforeRegistration() {
        defaults.set(true, forKey: LaunchAtLoginController.desiredKey)
        defaults.set("1.0.0", forKey: LaunchAtLoginController.registeredBuildKey)
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = makeController(service: service, build: "2.0.0")

        controller.reconcileInstalledBuild()

        XCTAssertEqual(service.calls, [.unregister, .register])
        XCTAssertEqual(defaults.string(forKey: LaunchAtLoginController.registeredBuildKey), "2.0.0")
    }

    func testMissingRegistrationIsRestoredForOptedInUser() {
        defaults.set(true, forKey: LaunchAtLoginController.desiredKey)
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = makeController(service: service, build: "2.0.0")

        controller.reconcileInstalledBuild()

        XCTAssertEqual(service.calls, [.register])
        XCTAssertEqual(defaults.string(forKey: LaunchAtLoginController.registeredBuildKey), "2.0.0")
    }

    func testApprovalRequiredIsNeverOverridden() {
        defaults.set(true, forKey: LaunchAtLoginController.desiredKey)
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = makeController(service: service)

        controller.reconcileInstalledBuild()

        XCTAssertTrue(controller.requiresApproval)
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testFailedRefreshDoesNotAdvanceRegisteredBuild() {
        defaults.set(true, forKey: LaunchAtLoginController.desiredKey)
        defaults.set("1.0.0", forKey: LaunchAtLoginController.registeredBuildKey)
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.registerError = TestError.failed
        let controller = makeController(service: service, build: "2.0.0")

        controller.reconcileInstalledBuild()

        XCTAssertEqual(service.calls, [.unregister, .register])
        XCTAssertEqual(defaults.string(forKey: LaunchAtLoginController.registeredBuildKey), "1.0.0")
        XCTAssertNotNil(controller.lastError)
    }

    func testTurningOffPersistsOptOutAndUnregisters() {
        defaults.set(true, forKey: LaunchAtLoginController.desiredKey)
        defaults.set("2.0.0", forKey: LaunchAtLoginController.registeredBuildKey)
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = makeController(service: service)

        controller.setDesiredEnabled(false)

        XCTAssertFalse(controller.desiredEnabled)
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginController.desiredKey))
        XCTAssertNil(defaults.string(forKey: LaunchAtLoginController.registeredBuildKey))
        XCTAssertEqual(service.calls, [.unregister])
    }

    func testTurningOnRegistersAndPersistsCurrentBuild() {
        defaults.set(false, forKey: LaunchAtLoginController.desiredKey)
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = makeController(service: service, build: "2.0.0")

        controller.setDesiredEnabled(true)

        XCTAssertTrue(controller.desiredEnabled)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginController.desiredKey))
        XCTAssertEqual(defaults.string(forKey: LaunchAtLoginController.registeredBuildKey), "2.0.0")
        XCTAssertEqual(service.calls, [.register])
    }

    func testApprovalActionOpensLoginItemsSettings() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = makeController(service: service)

        controller.openLoginItemsSettings()

        XCTAssertEqual(service.calls, [.openSettings])
    }

    private func makeController(
        service: FakeLaunchAtLoginService,
        build: String = "1.0.0"
    ) -> LaunchAtLoginController {
        LaunchAtLoginController(service: service, defaults: defaults, currentBuild: build)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    enum Call: Equatable {
        case register
        case unregister
        case openSettings
    }

    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var calls: [Call] = []

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        calls.append(.register)
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        calls.append(.unregister)
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettingsLoginItems() {
        calls.append(.openSettings)
    }
}

private enum TestError: Error {
    case failed
}
