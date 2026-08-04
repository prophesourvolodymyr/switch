import AppKit
import ServiceManagement
import SwitchinToshCore

@MainActor
final class SettingsStoreBridge {
    let store: VersionedSettingsStore
    let secrets: SecretStore

    init(
        store: VersionedSettingsStore? = nil,
        secrets: SecretStore = KeychainSecretStore()
    ) {
        self.secrets = secrets
        if let store {
            self.store = store
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SwitchinTosh", isDirectory: true)
                .appendingPathComponent("F01", isDirectory: true)
            self.store = JSONFileSettingsStore(directoryURL: directory) { [secrets] scope in
                switch scope {
                case .pairedDevice(let deviceID): try secrets.delete(account: Self.deviceAccount(deviceID))
                case .entireF01Store:
                    for account in ["session", "host-key"] { try secrets.delete(account: account) }
                case .controlApp, .allControlApps: break
                }
            }
        }
    }

    func hostSettings(permissionModel: OnboardingModel? = nil) -> HostSettings {
        let launchAtLogin: Bool
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
        return (try? HostSettings(
            launchAtLogin: launchAtLogin,
            localDiscoveryEnabled: true,
            connectionPolicy: .localOnly,
            accessibilityGranted: permissionModel?.accessibility ?? AXIsProcessTrusted(),
            screenCaptureGranted: permissionModel?.screenCapture ?? CGPreflightScreenCaptureAccess()
        )) ?? .defaults
    }

    func remoteSettings() -> RemoteSettings { .defaults }

    func hostDocument(permissionModel: OnboardingModel? = nil) -> SettingsDocument {
        let settings = hostSettings(permissionModel: permissionModel)
        let values = (try? CanonicalJSONDecoder().decode(JSONValue.self, from: canonicalBytes(settings))) ?? .object([:])
        return (try? SettingsDocument(namespace: .host, schemaVersion: HostSettings.currentSchemaVersion, values: values))
            ?? (try! SettingsDocument(namespace: .host, schemaVersion: 1, values: .object([:])))
    }

    func writeHostDocument(permissionModel: OnboardingModel? = nil) {
        try? store.write(hostDocument(permissionModel: permissionModel))
    }

    func readDocument(namespace: SettingsNamespace) -> SettingsDocument? {
        try? store.read(namespace: namespace)
    }

    func writeDocument(_ document: SettingsDocument) throws {
        try store.write(document)
    }

    func migrateDocument(_ document: SettingsDocument, to schemaVersion: Int) throws -> SettingsDocument {
        try store.migrate(document, to: schemaVersion)
    }

    func reset(_ scope: SettingsResetScope) throws -> SettingsResetResult {
        let result = try store.reset(scope)
        switch scope {
        case .pairedDevice(let deviceID):
            try deleteDeviceSecrets(deviceID)
        case .entireF01Store:
            for account in ["session", "host-key"] {
                try secrets.delete(account: account)
            }
        case .controlApp, .allControlApps:
            break
        }
        return result
    }

    func deleteDeviceSecrets(_ deviceID: DeviceID) throws {
        try secrets.delete(account: Self.deviceAccount(deviceID))
        try secrets.delete(account: Self.sessionAccount(deviceID))
    }

    nonisolated static func deviceAccount(_ deviceID: DeviceID) -> String { "device.\(deviceID.rawValue)" }
    nonisolated static func sessionAccount(_ deviceID: DeviceID) -> String { "session.\(deviceID.rawValue)" }
}
