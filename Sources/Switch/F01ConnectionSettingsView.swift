import AppKit
import SwiftUI
import SwitchinToshCore

struct F01ConnectionSettingsView: View {
    @ObservedObject var service: ControlHostService
    @State private var pairingDisplay: PairingAttemptDisplay?
    @State private var resetConfirmation = false
    @State private var revokeConfirmation = false
    @State private var selectedDevice: DeviceID?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hostSummary
                pairingSection
                permissionSection
                installedAppsSection
                actionsSection
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .onChange(of: service.state) { _, state in
            if state == .unpaired || state == .securityFailure { pairingDisplay = nil }
        }
        .confirmationDialog("Reset all SwitchinTosh connection data?", isPresented: $resetConfirmation, titleVisibility: .visible) {
            Button("Reset F01 Store", role: .destructive) {
                do {
                    _ = try service.resetF01Store()
                    pairingDisplay = nil
                    message = "Connection data reset."
                } catch {
                    message = CoreError(code: .internalFailure).userMessage
                }
            }
        } message: {
            Text("This removes ordinary F01 settings and secure pairing records.")
        }
        .confirmationDialog("Revoke this paired device?", isPresented: $revokeConfirmation, titleVisibility: .visible) {
            Button("Revoke Device", role: .destructive) {
                guard let selectedDevice else { return }
                Task { @MainActor in
                    do {
                        try await service.revoke(deviceID: selectedDevice)
                        message = "Device revoked."
                    } catch let error as CoreError {
                        message = error.userMessage
                    } catch {
                        message = CoreError(code: .internalFailure).userMessage
                    }
                }
            }
        } message: {
            Text("The device will need to pair again before it can connect.")
        }
    }

    private var hostSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SwitchinTosh Connection")
                .font(.system(size: 16, weight: .semibold))
            Text(service.hostIdentity.displayName)
                .font(.system(size: 13, weight: .medium))
            Text(service.hostIdentity.accountLabel ?? "Local Mac")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Label(stateLabel, systemImage: stateSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(stateColor)
        }
    }

    private var pairingSection: some View {
        section("Pairing") {
            VStack(alignment: .leading, spacing: 10) {
                if let pairingDisplay {
                    Text("Short code")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(pairingDisplay.shortCode)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.disabled)
                    Text("Enter this code on the iPhone. It expires in five minutes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Start a local pairing attempt to show a short code on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let pending = service.pendingPairing {
                    Divider()
                    Text("Pending approval from \(pending.clientIdentity?.displayName ?? "an iPhone")")
                        .font(.system(size: 12, weight: .medium))
                    HStack {
                        Button("Accept") {
                            Task { @MainActor in
                                do {
                                    _ = try await service.approve(pending.id)
                                    pairingDisplay = nil
                                    message = "Device paired."
                                } catch let error as CoreError {
                                    message = error.userMessage
                                } catch {
                                    message = CoreError(code: .internalFailure).userMessage
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Reject", role: .cancel) {
                            do {
                                try service.reject(pending.id)
                                pairingDisplay = nil
                                message = "Pairing rejected."
                            } catch let error as CoreError {
                                message = error.userMessage
                            } catch {
                                message = CoreError(code: .internalFailure).userMessage
                            }
                        }
                    }
                }
                Button(pairingDisplay == nil ? "Begin Pairing" : "New Pairing") {
                    pairingDisplay = service.beginPairing()
                    message = nil
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(rowBackground)
        }
    }

    private var permissionSection: some View {
        section("Capabilities and permissions") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(service.snapshot?.capabilities ?? [], id: \.id) { capability in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: capability.availability == .available ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(capability.availability == .available ? .green : .secondary)
                        Text(capability.title)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(capability.availability.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Accessibility and Screen Recording keep their existing Switch meanings. F01 does not request them automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(rowBackground)
        }
    }

    private var installedAppsSection: some View {
        section("Installed control apps") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(service.snapshot?.installedControlApps ?? [], id: \.manifest.id) { app in
                    HStack {
                        Image(systemName: app.manifest.icon.value)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.manifest.displayName).font(.system(size: 12, weight: .medium))
                            Text("\(app.state.rawValue) · \(app.installedVersion.major).\(app.installedVersion.minor).\(app.installedVersion.patch)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(rowBackground)
        }
    }

    private var actionsSection: some View {
        HStack {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .controlSize(.small)
            Spacer()
            if let first = service.pairedDevices.first {
                Button("Revoke", role: .destructive) {
                    selectedDevice = first.identity.id
                    revokeConfirmation = true
                }
                .controlSize(.small)
            }
            Button("Reset F01 Store", role: .destructive) {
                resetConfirmation = true
            }
            .controlSize(.small)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private var stateLabel: String {
        switch service.state {
        case .unpaired: return "Not paired"
        case .pairing: return service.pendingPairing == nil ? "Pairing available" : "Awaiting approval"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .permissionRequired: return "Permission required"
        case .securityFailure: return "Security failure"
        }
    }

    private var stateSymbol: String {
        switch service.state {
        case .connected: return "checkmark.circle.fill"
        case .securityFailure: return "lock.trianglebadge.exclamationmark"
        case .reconnecting: return "arrow.clockwise"
        default: return "circle.dashed"
        }
    }

    private var stateColor: Color {
        switch service.state {
        case .connected: return .green
        case .securityFailure: return .red
        case .permissionRequired: return .orange
        default: return .secondary
        }
    }
}

private extension CapabilityAvailability {
    var label: String {
        switch self {
        case .available: return "Available"
        case .unsupported: return "Not implemented"
        case .permissionRequired: return "Permission required"
        }
    }
}
