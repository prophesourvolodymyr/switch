import XCTest
import CryptoKit
import SwitchinToshCore
@testable import SwitchinTosh

@MainActor
final class ControlHostLifecycleTests: XCTestCase {
    func testHostStartsAdvertisesSafeSnapshotAndStopsWithoutSystemSideEffects() throws {
        let secrets = InMemorySecretStore()
        let settings = SettingsStoreBridge(store: InMemoryVersionedSettingsStore(), secrets: secrets)
        let registry = CapabilityRegistry()
        let identity = try DeviceIdentity(
            id: try DeviceID("com.tosh.switchintosh"),
            role: .host,
            displayName: "Test Mac",
            accountLabel: "test",
            protocolRange: .initial,
            createdAt: Timestamp(millisecondsSince1970: 1_700_000_000_000)
        )
        let service = ControlHostService(
            secretStore: secrets,
            settingsBridge: settings,
            transportListener: nil,
            clock: FixedClock(Timestamp(millisecondsSince1970: 1_700_000_000_000)),
            capabilityRegistry: registry,
            hostIdentity: identity
        )
        service.start()
        XCTAssertEqual(service.state, .unpaired)
        XCTAssertEqual(service.hostIdentity, identity)
        XCTAssertEqual(service.snapshot?.connectionState, .unpaired)
        XCTAssertEqual(service.snapshot?.protocolVersion, .initial)
        XCTAssertEqual(service.snapshot?.installedControlApps.count, 1)
        XCTAssertEqual(service.snapshot?.capabilities.count, 8)
        XCTAssertTrue(service.pairedDevices.isEmpty)
        service.stop()
        XCTAssertEqual(service.state, .unpaired)
        XCTAssertNil(service.pendingPairing)
    }

    func testPairingSurfaceKeepsCodeEphemeralAndAcceptsOnlyExplicitApproval() async throws {
        let secrets = InMemorySecretStore()
        let service = ControlHostService(
            secretStore: secrets,
            settingsBridge: SettingsStoreBridge(store: InMemoryVersionedSettingsStore(), secrets: secrets),
            clock: FixedClock(Timestamp(millisecondsSince1970: 1_700_000_000_000))
        )
        let display = service.beginPairing()
        let key = KeyAgreementIdentity()
        let client = try DeviceIdentity(id: try DeviceID("iphone-test"), role: .remote, displayName: "Test iPhone", protocolRange: .initial, createdAt: display.attempt.createdAt)
        _ = try service.receivePairing(try PairingRequest(attemptID: display.attempt.id, hostID: .switchinTosh, clientIdentity: client, code: display.shortCode, clientPublicKey: key.publicKeyData))
        XCTAssertEqual(service.state, .pairing)
        XCTAssertEqual(service.pendingPairing?.clientIdentity, client)
        _ = try await service.approve(display.attempt.id)
        XCTAssertTrue(service.pairedDevices.contains { $0.identity.id == client.id })
        XCTAssertNil(service.pendingPairing)
        XCTAssertNil(try secrets.read(account: "pairing-code"))
    }
    func testSettingsResetDeletesOnlyRequestedSecureDeviceData() throws {
        let secrets = InMemorySecretStore()
        let bridge = SettingsStoreBridge(store: InMemoryVersionedSettingsStore(), secrets: secrets)
        let requested = try DeviceID("requested-device")
        let untouched = try DeviceID("untouched-device")
        try secrets.write(Data("requested".utf8), account: SettingsStoreBridge.deviceAccount(requested))
        try secrets.write(Data("untouched".utf8), account: SettingsStoreBridge.deviceAccount(untouched))

        let result = try bridge.reset(.pairedDevice(requested))

        XCTAssertEqual(result.scope, .pairedDevice(requested))
        XCTAssertNil(try secrets.read(account: SettingsStoreBridge.deviceAccount(requested)))
        XCTAssertEqual(
            try secrets.read(account: SettingsStoreBridge.deviceAccount(untouched)),
            Data("untouched".utf8)
        )
    }

    func testCatalogAndPackageLifecycleRemainBounded() async throws {
        let artifact = try makeSignedArtifact()
        let service = ControlHostService(
            secretStore: InMemorySecretStore(),
            settingsBridge: SettingsStoreBridge(
                store: InMemoryVersionedSettingsStore(),
                secrets: InMemorySecretStore()
            ),
            clock: FixedClock(Timestamp(millisecondsSince1970: 1_700_000_000_000)),
            marketplaceCatalogClient: FixtureCatalogClient(
                response: CatalogResponse(products: [], state: .populated)
            ),
            packageArtifactClient: FixturePackageClient(artifact: artifact)
        )

        let response = try await service.fetchCatalog(try CatalogQuery())
        XCTAssertEqual(response.state, .populated)
        let installed = try await service.installPackage(packageID: artifact.packageID, version: artifact.version)
        XCTAssertEqual(installed.state, .active)
        XCTAssertEqual(service.installedControlApps.count, 2)
        XCTAssertEqual(service.snapshot?.installedControlApps.count, 2)

        XCTAssertEqual(try service.disablePackage(packageID: artifact.packageID).state, .disabled)
        XCTAssertEqual(try service.enablePackage(packageID: artifact.packageID).state, .active)
        let revoked = try service.revokePackage(packageID: artifact.packageID)
        XCTAssertEqual(revoked.state, .revoked)
        XCTAssertEqual(service.installedControlApps.first?.manifest.id, .default)
        XCTAssertEqual(service.installedControlApps.first?.state, .active)
        _ = try service.resetF01Store()
        XCTAssertEqual(service.installedControlApps.count, 1)
        XCTAssertEqual(service.state, .unpaired)
    }

    private func makeSignedArtifact() throws -> PackageArtifact {
        let id = try PackageID("launchintosh-fixture")
        let signer = Curve25519.Signing.PrivateKey()
        let versionRange = try VersionRange(minimum: .initial)
        let manifest = try ControlAppManifest(
            id: try ControlAppID(id.rawValue),
            displayName: "Launchintosh Fixture",
            version: .initial,
            icon: try IconMetadata(kind: .initials, value: "L", accessibilityLabel: "Launchintosh"),
            supportedPlatformVersions: versionRange,
            requiredCapabilities: [.apps],
            permissionExplanations: [
                try PermissionExplanation(
                    permissionID: .accessibility,
                    title: "Accessibility",
                    explanation: "Allows approved app control."
                )
            ],
            settingsSchema: try SettingsSchema(version: 1, fields: []),
            gestureClaims: [
                try GestureClaim(
                    fingerCount: 2,
                    direction: .horizontal,
                    name: "Switch mode",
                    fallbackActionLabel: "Switch mode"
                )
            ],
            surfaceIdentity: "launchintosh.fixture",
            migrationVersion: 1
        )
        let bytes = Data("launchintosh-fixture".utf8)
        let placeholder = try PackageSignature(
            keyID: "fixture-key",
            publicKey: signer.publicKey.rawRepresentation,
            signature: Data([0])
        )
        let unsigned = PackageArtifact(
            packageID: id,
            manifest: manifest,
            bytes: bytes,
            digest: sha256Digest(bytes),
            signature: placeholder
        )
        let signature = try signer.signature(for: unsigned.signingPayload())
        return PackageArtifact(
            packageID: id,
            manifest: manifest,
            bytes: bytes,
            digest: sha256Digest(bytes),
            signature: try PackageSignature(
                keyID: "fixture-key",
                publicKey: signer.publicKey.rawRepresentation,
                signature: signature
            )
        )
    }
}

private struct FixtureCatalogClient: MarketplaceCatalogClient {
    let response: CatalogResponse

    func fetchCatalog(_ query: CatalogQuery) async throws -> CatalogResponse {
        response
    }
}

private struct FixturePackageClient: PackageArtifactClient {
    let artifact: PackageArtifact

    func fetchArtifact(packageID: PackageID, version: PackageVersion) async throws -> PackageArtifact {
        guard packageID == artifact.packageID, version == artifact.version else {
            throw CoreError(code: .packageConflict)
        }
        return artifact
    }
}
