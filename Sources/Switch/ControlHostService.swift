import Foundation
import Combine
import SwitchinToshCore

@MainActor
final class ControlHostService: ObservableObject {
    @Published private(set) var state: HostConnectionState = .unpaired
    @Published private(set) var hostIdentity: DeviceIdentity
    @Published private(set) var snapshot: StateSnapshot?
    @Published private(set) var pendingPairing: PairingAttempt?
    @Published private(set) var catalogResponse: CatalogResponse?

    let settingsBridge: SettingsStoreBridge
    let secretStore: SecretStore
    let transportListener: TransportHost?
    let clock: CoreClock
    let capabilityRegistry: CapabilityRegistry
    let pairingCoordinator: PairingCoordinator
    let packageLifecycleManager: PackageLifecycleManager
    let marketplaceCatalogClient: MarketplaceCatalogClient?
    let packageArtifactClient: PackageArtifactClient?
    private(set) var actionRouter: ActionRouter?
    private var started = false

    var pairedDevices: [PairedDevice] { pairingCoordinator.pairedDevices }

    init(
        secretStore: SecretStore = KeychainSecretStore(),
        settingsBridge: SettingsStoreBridge? = nil,
        transportListener: TransportHost? = nil,
        clock: CoreClock = SystemClock(),
        capabilityRegistry: CapabilityRegistry? = nil,
        hostIdentity: DeviceIdentity? = nil,
        packageLifecycleManager: PackageLifecycleManager? = nil,
        marketplaceCatalogClient: MarketplaceCatalogClient? = nil,
        packageArtifactClient: PackageArtifactClient? = nil
    ) {
        self.secretStore = secretStore
        self.settingsBridge = settingsBridge ?? SettingsStoreBridge(secrets: secretStore)
        self.transportListener = transportListener
        self.clock = clock
        self.capabilityRegistry = capabilityRegistry ?? CapabilityRegistry()
        let identity = hostIdentity ?? (try! DeviceIdentity(
            id: try! DeviceID(ProtocolConstants.hostID),
            role: .host,
            displayName: HostProcessIdentity.displayName,
            accountLabel: HostProcessIdentity.accountLabel,
            protocolRange: .initial,
            createdAt: clock.now()
        ))
        self.hostIdentity = identity
        self.pairingCoordinator = PairingCoordinator(
            hostIdentity: identity,
            secrets: secretStore,
            clock: clock
        )
        self.marketplaceCatalogClient = marketplaceCatalogClient
        self.packageArtifactClient = packageArtifactClient
        let compatibility = HostCompatibilityContext(
            hostID: try! HostID(identity.id.rawValue),
            hostVersion: .initial,
            sdkVersion: .initial,
            platformVersion: .initial
        )
        self.packageLifecycleManager = packageLifecycleManager ?? (try! PackageLifecycleManager(
            artifactStore: InMemoryArtifactStore(),
            compatibility: compatibility,
            clock: clock
        ))
        self.snapshot = nil
        self.catalogResponse = nil
        self.actionRouter = nil
        self.actionRouter = ActionRouter(registry: self.capabilityRegistry, clock: clock) { [weak self] in
            self?.snapshot
        }
        refreshSnapshot()
    }

    func start() {
        guard !started else { return }
        started = true
        state = .unpaired
        settingsBridge.writeHostDocument()
        refreshSnapshot()
        guard let transportListener else { return }
        Task { @MainActor [weak self] in
            do {
                try await transportListener.start()
            } catch {
                self?.state = .securityFailure
                self?.refreshSnapshot()
            }
        }
    }

    func stop() {
        started = false
        if let transportListener {
            Task { await transportListener.stop() }
        }
        pendingPairing = nil
        state = .unpaired
        refreshSnapshot()
    }

    func beginPairing() -> PairingAttemptDisplay {
        state = .pairing
        let display = pairingCoordinator.beginPairing()
        pendingPairing = nil
        refreshSnapshot()
        return display
    }

    func receivePairing(_ request: PairingRequest) throws -> PairingAttempt {
        let attempt = try pairingCoordinator.receive(request)
        pendingPairing = attempt
        state = .pairing
        refreshSnapshot()
        return attempt
    }

    func approve(_ attemptID: PairingAttemptID) async throws -> PairedDevice {
        let device = try await pairingCoordinator.approve(attemptID)
        pendingPairing = nil
        state = .pairing
        refreshSnapshot()
        return device
    }

    func reject(_ attemptID: PairingAttemptID) throws {
        try pairingCoordinator.reject(attemptID)
        pendingPairing = nil
        state = .unpaired
        refreshSnapshot()
    }

    func revoke(deviceID: DeviceID) async throws {
        try await pairingCoordinator.revoke(deviceID: deviceID)
        try settingsBridge.deleteDeviceSecrets(deviceID)
        if pairedDevices.isEmpty { state = .unpaired }
        refreshSnapshot()
    }

    func setPermission(_ permissionID: PermissionID, state: PermissionGrantState) {
        capabilityRegistry.setPermission(permissionID, state: state)
        refreshSnapshot()
    }

    func registerFixtureAdapter(
        for capabilityID: CapabilityID,
        adapter: @escaping @Sendable (String, JSONValue) throws -> JSONValue
    ) {
        capabilityRegistry.registerFixtureAdapter(for: capabilityID, adapter: adapter)
        refreshSnapshot()
    }

    func authenticate(sessionID: SessionID) {
        actionRouter?.authenticate(sessionID: sessionID)
    }

    func dispatch(_ request: ActionRequest) -> ActionRouter.DispatchResult? {
        actionRouter?.dispatch(request)
    }
 
    var installedControlApps: [InstalledControlApp] {
        packageLifecycleManager.allInstalled()
    }
 
    func fetchCatalog(_ query: CatalogQuery) async throws -> CatalogResponse {
        guard let marketplaceCatalogClient else {
            throw CoreError(code: .unavailableCapability)
        }
        let response = try await marketplaceCatalogClient.fetchCatalog(query)
        catalogResponse = response
        return response
    }
 
    func installPackage(packageID: PackageID, version: PackageVersion) async throws -> InstalledControlApp {
        guard let packageArtifactClient else {
            throw CoreError(code: .unavailableCapability)
        }
        let artifact = try await packageArtifactClient.fetchArtifact(packageID: packageID, version: version)
        return try installPackage(artifact)
    }
 
    func installPackage(_ artifact: PackageArtifact) throws -> InstalledControlApp {
        let installed = try packageLifecycleManager.install(artifact)
        refreshSnapshot()
        return installed
    }
 
    func updatePackage(_ artifact: PackageArtifact) throws -> InstalledControlApp {
        let updated = try packageLifecycleManager.update(artifact)
        refreshSnapshot()
        return updated
    }
 
    func enablePackage(packageID: PackageID) throws -> InstalledControlApp {
        let enabled = try packageLifecycleManager.enable(packageID: packageID)
        refreshSnapshot()
        return enabled
    }
 
    func disablePackage(packageID: PackageID) throws -> InstalledControlApp {
        let disabled = try packageLifecycleManager.disable(packageID: packageID)
        refreshSnapshot()
        return disabled
    }
 
    func removePackage(packageID: PackageID) throws -> InstalledControlApp {
        let removed = try packageLifecycleManager.remove(packageID: packageID)
        refreshSnapshot()
        return removed
    }
 
    func quarantinePackage(packageID: PackageID) throws -> InstalledControlApp {
        let quarantined = try packageLifecycleManager.quarantine(packageID: packageID)
        refreshSnapshot()
        return quarantined
    }
 
    func revokePackage(packageID: PackageID) throws -> InstalledControlApp {
        let revoked = try packageLifecycleManager.revoke(packageID: packageID)
        _ = try settingsBridge.reset(.controlApp(try ControlAppID(packageID.rawValue)))
        refreshSnapshot()
        return revoked
    }
 
    func rollbackPackage(packageID: PackageID) throws -> InstalledControlApp {
        let rolledBack = try packageLifecycleManager.rollback(packageID: packageID)
        refreshSnapshot()
        return rolledBack
    }

    func resetF01Store() throws -> SettingsResetResult {
        let result = try settingsBridge.reset(.entireF01Store)
        try packageLifecycleManager.resetMarketplace()
        try pairingCoordinator.resetAll()
        state = .unpaired
        pendingPairing = nil
        refreshSnapshot()
        return result
    }

    private func refreshSnapshot() {
        snapshot = try? StateSnapshot(
            connectionState: state,
            hostIdentity: hostIdentity,
            protocolVersion: .initial,
            capabilities: capabilityRegistry.allCapabilities(),
            permissions: capabilityRegistry.allPermissionGrants(),
            installedControlApps: packageLifecycleManager.allInstalled(),
            settingsVersion: 1,
            lastEventSequence: 0
        )
    }
}

enum HostProcessIdentity {
    static let displayName = Host.current().localizedName ?? "This Mac"
    static let accountLabel = NSUserName()
}
