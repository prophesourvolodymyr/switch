import Foundation
import SwitchinToshCore

@MainActor
final class CapabilityRegistry: ObservableObject {
    private(set) var capabilities: [CapabilityID: Capability]
    private var fixtureAdapters: [CapabilityID: @Sendable (String, JSONValue) throws -> JSONValue] = [:]
    private var permissionGrants: [PermissionID: PermissionGrantState] = [:]

    init() {
        capabilities = [:]
        registerDefaults()
    }

    func capability(_ id: CapabilityID) -> Capability? { capabilities[id] }

    func allCapabilities() -> [Capability] {
        capabilities.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func allPermissionGrants() -> [PermissionGrant] {
        permissionGrants
            .map { PermissionGrant(permissionID: $0.key, state: $0.value, grantedAt: $0.value == .granted ? .now : nil) }
            .sorted { $0.permissionID.rawValue < $1.permissionID.rawValue }
    }

    func setPermission(_ permissionID: PermissionID, state: PermissionGrantState) {
        permissionGrants[permissionID] = state
        for (id, capability) in capabilities where capability.permissionID == permissionID {
            let availability: CapabilityAvailability = state == .granted ? .available : .permissionRequired
            capabilities[id] = try? Capability(
                id: capability.id,
                title: capability.title,
                explanation: capability.explanation,
                risk: capability.risk,
                permissionID: capability.permissionID,
                supportedActions: capability.supportedActions,
                availability: availability
            )
        }
    }

    func registerFixtureAdapter(
        for capabilityID: CapabilityID,
        adapter: @escaping @Sendable (String, JSONValue) throws -> JSONValue
    ) {
        fixtureAdapters[capabilityID] = adapter
        guard let capability = capabilities[capabilityID] else { return }
        capabilities[capabilityID] = try? Capability(
            id: capability.id,
            title: capability.title,
            explanation: capability.explanation,
            risk: capability.risk,
            permissionID: capability.permissionID,
            supportedActions: capability.supportedActions,
            availability: .available
        )
    }

    func performFixtureAction(capabilityID: CapabilityID, actionName: String, input: JSONValue) throws -> JSONValue {
        guard let adapter = fixtureAdapters[capabilityID] else { throw CoreError(code: .unavailableCapability) }
        return try adapter(actionName, input)
    }

    func permissionState(_ permissionID: PermissionID) -> PermissionGrantState {
        permissionGrants[permissionID] ?? .notRequested
    }

    private func registerDefaults() {
        let definitions: [(CapabilityID, String, String, CapabilityRisk, PermissionID?, [String], CapabilityAvailability)] = [
            (.windows, "Windows", "Inspect and focus approved Mac windows.", .high, .accessibility, ["focus", "close", "hide"], .permissionRequired),
            (.apps, "Apps", "Launch and focus approved Mac apps.", .medium, .accessibility, ["launch", "focus"], .permissionRequired),
            (.workspaces, "Workspaces", "Switch between Mac workspaces.", .medium, .accessibility, ["next", "previous"], .permissionRequired),
            (.media, "Media", "Control supported media sessions.", .low, nil, ["playPause", "next", "previous"], .unsupported),
            (.websites, "Websites", "Open approved websites.", .medium, nil, ["open"], .unsupported),
            (.terminalSessions, "Terminal sessions", "Connect to approved terminal sessions.", .sensitive, .terminal, ["list", "focus"], .unsupported),
            (.aiSessions, "AI sessions", "Connect to approved AI sessions.", .sensitive, .terminal, ["list", "focus"], .unsupported),
            (.installedControlApps, "Installed control apps", "Inspect installed control-app metadata.", .low, nil, ["list"], .available)
        ]
        for definition in definitions {
            capabilities[definition.0] = try? Capability(
                id: definition.0,
                title: definition.1,
                explanation: definition.2,
                risk: definition.3,
                permissionID: definition.4,
                supportedActions: definition.5,
                availability: definition.6
            )
        }
        permissionGrants[.accessibility] = .notRequested
        permissionGrants[.screenCapture] = .notRequested
        permissionGrants[.terminal] = .notRequested
    }
}
