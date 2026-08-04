import Foundation
import SwitchinToshCore

@MainActor
final class PairingCoordinator: ObservableObject {
    private let hostIdentity: DeviceIdentity
    private let hostID: HostID
    private let secrets: SecretStore
    private let clock: CoreClock
    private var activeCode: String?
    private var activeClientPublicKey: Data?
    private var activeAttempt: PairingAttempt?

    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var pendingAttempt: PairingAttempt?

    init(
        hostIdentity: DeviceIdentity,
        hostID: HostID = .switchinTosh,
        secrets: SecretStore,
        clock: CoreClock = SystemClock()
    ) {
        self.hostIdentity = hostIdentity
        self.hostID = hostID
        self.secrets = secrets
        self.clock = clock
    }

    func beginPairing() -> PairingAttemptDisplay {
        expireIfNeeded()
        let now = clock.now()
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        let attempt = try! PairingAttempt(
            id: try! PairingAttemptID(UUID().uuidString.lowercased()),
            hostIdentity: hostIdentity,
            createdAt: now,
            expiresAt: now.adding(milliseconds: TransportPolicy.pairingCodeLifetimeMilliseconds),
            status: .pending,
            codeDigest: sha256Digest(Data(code.utf8))
        )
        activeAttempt = attempt
        activeCode = code
        activeClientPublicKey = nil
        pendingAttempt = nil
        return try! PairingAttemptDisplay(attempt: attempt, shortCode: code)
    }

    func receive(_ request: PairingRequest) throws -> PairingAttempt {
        expireIfNeeded()
        guard let attempt = activeAttempt, let code = activeCode, attempt.id == request.attemptID,
              request.hostID == hostID, attempt.status == .pending,
              request.clientIdentity.role == .remote else {
            throw CoreError(code: .invalidInput)
        }
        guard !attempt.isExpired(at: clock.now()) else {
            clearActive(status: .expired)
            throw CoreError(code: .staleRequest)
        }
        guard sha256Digest(Data(code.utf8)) == attempt.codeDigest, !request.clientPublicKey.isEmpty else {
            throw CoreError(code: .invalidInput)
        }
        let updated = try PairingAttempt(
            id: attempt.id,
            hostIdentity: attempt.hostIdentity,
            createdAt: attempt.createdAt,
            expiresAt: attempt.expiresAt,
            status: .pending,
            codeDigest: attempt.codeDigest,
            clientIdentity: request.clientIdentity
        )
        activeAttempt = updated
        activeClientPublicKey = request.clientPublicKey
        pendingAttempt = updated
        return updated
    }

    func approve(_ attemptID: PairingAttemptID) async throws -> PairedDevice {
        expireIfNeeded()
        guard let attempt = activeAttempt, attempt.id == attemptID,
              let client = attempt.clientIdentity,
              let publicKey = activeClientPublicKey,
              attempt.status == .pending else {
            throw CoreError(code: .staleRequest)
        }
        guard !attempt.isExpired(at: clock.now()) else {
            clearActive(status: .expired)
            throw CoreError(code: .staleRequest)
        }
        let now = clock.now()
        let paired = PairedDevice(identity: client, pairedAt: now, lastSeenAt: now)
        try secrets.write(publicKey, account: SettingsStoreBridge.deviceAccount(client.id))
        pairedDevices.removeAll { $0.identity.id == client.id }
        pairedDevices.append(paired)
        clearActive(status: .approved)
        return paired
    }

    func reject(_ attemptID: PairingAttemptID) throws {
        guard let attempt = activeAttempt, attempt.id == attemptID, attempt.status == .pending else {
            throw CoreError(code: .staleRequest)
        }
        clearActive(status: .rejected)
    }

    func revoke(deviceID: DeviceID) async throws {
        guard pairedDevices.contains(where: { $0.identity.id == deviceID }) else {
            throw CoreError(code: .invalidInput)
        }
        pairedDevices.removeAll { $0.identity.id == deviceID }
        try secrets.delete(account: SettingsStoreBridge.deviceAccount(deviceID))
        try secrets.delete(account: SettingsStoreBridge.sessionAccount(deviceID))
    }

    func resetAll() throws {
        for device in pairedDevices {
            try secrets.delete(account: SettingsStoreBridge.deviceAccount(device.identity.id))
            try secrets.delete(account: SettingsStoreBridge.sessionAccount(device.identity.id))
        }
        pairedDevices.removeAll()
        if activeAttempt != nil {
            clearActive(status: .rejected)
        }
    }

    func expireIfNeeded() {
        guard let attempt = activeAttempt, attempt.isExpired(at: clock.now()) else { return }
        clearActive(status: .expired)
    }

    private func clearActive(status: PairingAttemptStatus) {
        if let attempt = activeAttempt {
            activeAttempt = try? PairingAttempt(
                id: attempt.id,
                hostIdentity: attempt.hostIdentity,
                createdAt: attempt.createdAt,
                expiresAt: attempt.expiresAt,
                status: status,
                codeDigest: attempt.codeDigest,
                clientIdentity: attempt.clientIdentity
            )
        }
        activeCode = nil
        activeClientPublicKey = nil
        pendingAttempt = nil
        activeAttempt = nil
    }
}
