import SwiftUI
import UIKit

struct SettingsView: View {
    @Bindable var controller: RemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var manualAddress: String
    @State private var wakeMAC: String
    @State private var confirmForget = false

    init(controller: RemoteController) {
        self.controller = controller
        _manualAddress = State(initialValue: controller.settings.manualAddress)
        _wakeMAC = State(initialValue: controller.settings.manualMACAddress)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    identityPanel
                    networkPanel
                    troubleshootingPanel
                    forgetPanel
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.vizioGround.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 8) {
            if let error = controller.errorBanner {
                ErrorBanner(message: error, dismiss: controller.dismissError)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if let status = controller.successStatus {
                SuccessBanner(message: status, dismiss: controller.clearSuccessStatus)
            }
        }
        .confirmationDialog(
            "Forget this TV?",
            isPresented: $confirmForget,
            titleVisibility: .visible
        ) {
            Button("Forget TV and Erase Pairing Token", role: .destructive) {
                Task { @MainActor in
                    do {
                        try await controller.forgetDevice()
                        dismiss()
                    } catch { }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The paired TV metadata and protected Keychain token will be erased. Saved macros remain on this iPhone.")
        }
    }

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Paired TV",
                detail: "The certificate and TV identity are verified before a changed address is trusted."
            )
            VizioInfoRow(label: "Name", value: controller.pairedDevice?.name ?? "Unavailable")
            if let model = controller.pairedDevice?.model, !model.isEmpty {
                VizioInfoRow(label: "Model", value: model)
            }
            if let serial = controller.pairedDevice?.serial, !serial.isEmpty {
                VizioInfoRow(label: "Serial", value: serial)
            }
            VizioInfoRow(
                label: "Current endpoint",
                value: controller.tvState.endpoint?.host ?? controller.pairedDevice?.endpoint.host ?? "Unavailable"
            )
            VizioInfoRow(label: "Connection", value: controller.tvState.connected ? "Connected" : "Offline")
            AsyncActionButton(
                title: "Refresh and Verify",
                systemImage: "arrow.clockwise",
                kind: .primary,
                accessibilityHint: "Checks state and verifies identity before accepting a changed address",
                action: { _ = await controller.refreshTVState() }
            )
        }
        .vizioPanel()
    }

    private var networkPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(
                title: "Network fallbacks",
                detail: "These values stay on this iPhone. A manual endpoint is only a rediscovery hint; Refresh still verifies the paired TV."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Manual hostname or IP")
                    .font(.subheadline.weight(.semibold))
                TextField("Private LAN hostname or IP", text: $manualAddress)
                    .vizioField()
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(saveManualAddress)
                    .accessibilityHint("Used only as a verified rediscovery hint")
                AsyncActionButton(
                    title: "Save Address Hint",
                    systemImage: "network",
                    kind: .quiet,
                    action: {
                        try await controller.saveManualEndpoint(manualAddress)
                        manualAddress = controller.settings.manualAddress
                    }
                )
            }

            Divider().overlay(Color.vizioRaised)

            VStack(alignment: .leading, spacing: 8) {
                Text("Wake MAC address")
                    .font(.subheadline.weight(.semibold))
                TextField("AA:BB:CC:DD:EE:FF", text: $wakeMAC)
                    .vizioField()
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(saveWakeMAC)
                    .accessibilityHint("A unicast TV address used only for Wake-on-LAN")
                Text("Saving a nonempty value immediately replaces the paired wake address. Clearing it disables Wake until discovery or a later entry restores one.")
                    .font(.footnote)
                    .foregroundStyle(Color.vizioMuted)
                    .fixedSize(horizontal: false, vertical: true)
                AsyncActionButton(
                    title: wakeMAC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Clear Wake Address" : "Save Wake Address",
                    systemImage: "wake",
                    kind: .quiet,
                    action: {
                        try await controller.saveWakeMAC(wakeMAC)
                        wakeMAC = controller.settings.manualMACAddress
                    }
                )
            }
        }
        .vizioPanel()
    }

    private var troubleshootingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Local Network troubleshooting")
            Text("Keep iPhone and TV on the same private Wi-Fi network. If discovery was denied, allow Local Network access in iOS Settings. Client isolation, guest Wi-Fi, or a VPN can also block direct TV traffic.")
                .font(.subheadline)
                .foregroundStyle(Color.vizioMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Label("Open iOS Settings", systemImage: "gear")
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityHint("Opens VizioControl’s iOS settings")
        }
        .vizioPanel()
    }

    private var forgetPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Forget TV",
                detail: "This erases paired TV metadata and its protected local token. Saved macro cards remain."
            )
            Button {
                confirmForget = true
            } label: {
                Label("Forget TV and erase the local pairing token", systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle())
            .accessibilityHint("Shows a destructive confirmation before erasing pairing")
        }
        .vizioPanel()
    }

    private func saveManualAddress() {
        Task { @MainActor in
            do {
                try await controller.saveManualEndpoint(manualAddress)
                manualAddress = controller.settings.manualAddress
            } catch { }
        }
    }

    private func saveWakeMAC() {
        Task { @MainActor in
            do {
                try await controller.saveWakeMAC(wakeMAC)
                wakeMAC = controller.settings.manualMACAddress
            } catch { }
        }
    }
}
