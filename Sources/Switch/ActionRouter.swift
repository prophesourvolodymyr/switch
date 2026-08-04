import Foundation
import SwitchinToshCore

@MainActor
final class ActionRouter {
    struct DispatchResult {
        let acknowledgement: Acknowledgement
        let result: ActionResult
    }

    private struct CachedResult {
        let payloadDigest: String
        let result: ActionResult
    }

    private let registry: CapabilityRegistry
    private let clock: CoreClock
    private let snapshotProvider: () -> StateSnapshot?
    private var authenticatedSessions: Set<SessionID> = []
    private var cache: [RequestID: CachedResult] = [:]

    init(
        registry: CapabilityRegistry,
        clock: CoreClock = SystemClock(),
        snapshotProvider: @escaping () -> StateSnapshot?
    ) {
        self.registry = registry
        self.clock = clock
        self.snapshotProvider = snapshotProvider
    }

    func authenticate(sessionID: SessionID) {
        authenticatedSessions.insert(sessionID)
    }

    func revoke(sessionID: SessionID) {
        authenticatedSessions.remove(sessionID)
    }

    func dispatch(_ request: ActionRequest) -> DispatchResult {
        let acceptedAt = clock.now()
        if let cached = cache[request.requestID] {
            if cached.payloadDigest == request.payloadDigest {
                return DispatchResult(
                    acknowledgement: Acknowledgement(requestID: request.requestID, acceptedAt: acceptedAt, duplicate: true),
                    result: cached.result
                )
            }
            return DispatchResult(
                acknowledgement: Acknowledgement(requestID: request.requestID, acceptedAt: acceptedAt),
                result: ActionResult(requestID: request.requestID, outcome: .failure(CoreError(code: .invalidInput)), completedAt: acceptedAt)
            )
        }

        let result: ActionResult
        if !authenticatedSessions.contains(request.sessionID) {
            result = failure(request, code: .disconnectedHost, at: acceptedAt)
        } else if request.isExpired(at: acceptedAt) {
            result = failure(request, code: .staleRequest, at: acceptedAt)
        } else if snapshotProvider()?.connectionState != .connected {
            result = failure(request, code: .disconnectedHost, at: acceptedAt)
        } else if let capability = registry.capability(request.capabilityID) {
            result = route(request, capability: capability, at: acceptedAt)
        } else {
            result = failure(request, code: .unavailableCapability, at: acceptedAt)
        }

        cache[request.requestID] = CachedResult(payloadDigest: request.payloadDigest, result: result)
        if cache.count > TransportPolicy.eventCacheCapacity,
           let oldest = cache.keys.min(by: { $0.rawValue < $1.rawValue }) {
            cache.removeValue(forKey: oldest)
        }
        return DispatchResult(acknowledgement: Acknowledgement(requestID: request.requestID, acceptedAt: acceptedAt), result: result)
    }

    private func route(_ request: ActionRequest, capability: Capability, at timestamp: Timestamp) -> ActionResult {
        guard capability.availability == .available else {
            return failure(request, code: capability.availability == .permissionRequired ? .deniedPermission : .unavailableCapability, at: timestamp)
        }
        guard capability.supportedActions.contains(request.actionName) else {
            return failure(request, code: .invalidInput, at: timestamp)
        }
        if let permissionID = capability.permissionID,
           registry.permissionState(permissionID) != .granted {
            return failure(request, code: .deniedPermission, at: timestamp)
        }
        do {
            let value = try registry.performFixtureAction(capabilityID: request.capabilityID, actionName: request.actionName, input: request.input)
            return ActionResult(requestID: request.requestID, outcome: .success(value), completedAt: timestamp)
        } catch let error as CoreError {
            return ActionResult(requestID: request.requestID, outcome: .failure(error), completedAt: timestamp)
        } catch {
            return failure(request, code: .internalFailure, at: timestamp)
        }
    }

    private func failure(_ request: ActionRequest, code: CoreErrorCode, at timestamp: Timestamp) -> ActionResult {
        ActionResult(requestID: request.requestID, outcome: .failure(CoreError(code: code)), completedAt: timestamp)
    }
}
