import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

@MainActor
struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Owns the user's launch-at-login intent and reconciles it with the current
/// application build registered in Service Management.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let desiredKey = "launchAtLoginDesired"
    static let registeredBuildKey = "launchAtLoginRegisteredBuildVersion"

    @Published private(set) var desiredEnabled: Bool
    @Published private(set) var systemStatus: SMAppService.Status
    @Published private(set) var lastError: String?

    private let service: any LaunchAtLoginServicing
    private let defaults: UserDefaults
    private let currentBuild: String

    var requiresApproval: Bool {
        desiredEnabled && systemStatus == .requiresApproval
    }

    var isEffective: Bool {
        systemStatus == .enabled
    }

    convenience init(
        defaults: UserDefaults = .standard,
        currentBuild: String? = nil
    ) {
        self.init(
            service: SystemLaunchAtLoginService(),
            defaults: defaults,
            currentBuild: currentBuild
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown"
        )
    }

    init(
        service: any LaunchAtLoginServicing,
        defaults: UserDefaults,
        currentBuild: String
    ) {
        self.service = service
        self.defaults = defaults
        self.currentBuild = currentBuild

        let initialStatus = service.status
        systemStatus = initialStatus
        if defaults.object(forKey: Self.desiredKey) == nil {
            desiredEnabled = initialStatus == .enabled
            defaults.set(desiredEnabled, forKey: Self.desiredKey)
        } else {
            desiredEnabled = defaults.bool(forKey: Self.desiredKey)
        }
        lastError = nil
    }

    /// Refresh an enabled registration after an app replacement, or restore a
    /// registration that disappeared while the user's intent remains enabled.
    func reconcileInstalledBuild() {
        refreshStatus()
        guard desiredEnabled else { return }

        switch systemStatus {
        case .enabled:
            guard defaults.string(forKey: Self.registeredBuildKey) != currentBuild else {
                return
            }
            reregisterCurrentBuild()
        case .notRegistered:
            registerCurrentBuild()
        case .requiresApproval:
            // The user denied this item in System Settings. Preserve their
            // in-app preference, but never try to override the system choice.
            return
        case .notFound:
            report("service was not found")
        @unknown default:
            report("service returned an unknown status")
        }
    }

    func setDesiredEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        defaults.set(enabled, forKey: Self.desiredKey)
        lastError = nil
        refreshStatus()

        if enabled {
            switch systemStatus {
            case .enabled:
                if defaults.string(forKey: Self.registeredBuildKey) == currentBuild {
                    lastError = nil
                } else {
                    reregisterCurrentBuild()
                }
            case .notRegistered, .notFound:
                registerCurrentBuild()
            case .requiresApproval:
                break
            @unknown default:
                report("service returned an unknown status")
            }
        } else {
            unregister()
        }
    }

    func refreshStatus() {
        systemStatus = service.status
    }

    func openLoginItemsSettings() {
        service.openSystemSettingsLoginItems()
    }

    private func registerCurrentBuild() {
        do {
            try service.register()
            defaults.set(currentBuild, forKey: Self.registeredBuildKey)
            lastError = nil
        } catch {
            report("registration failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    private func reregisterCurrentBuild() {
        do {
            try service.unregister()
            try service.register()
            defaults.set(currentBuild, forKey: Self.registeredBuildKey)
            lastError = nil
        } catch {
            report("refresh failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    private func unregister() {
        guard systemStatus != .notRegistered else {
            defaults.removeObject(forKey: Self.registeredBuildKey)
            return
        }

        do {
            try service.unregister()
            defaults.removeObject(forKey: Self.registeredBuildKey)
            lastError = nil
        } catch {
            report("unregistration failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    private func report(_ message: String) {
        lastError = message
        NSLog("omlxbar: launch-at-login \(message)")
    }
}
