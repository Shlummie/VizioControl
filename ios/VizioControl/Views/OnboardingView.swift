import SwiftUI
import UIKit

struct OnboardingView: View {
    @Bindable var controller: RemoteController
    @State private var manualAddress: String
    @State private var wakeMAC: String
    @State private var isPreparingDiscovery = false
    @State private var showPIN = false

    init(controller: RemoteController) {
        self.controller = controller
        _manualAddress = State(initialValue: controller.settings.manualAddress)
        _wakeMAC = State(initialValue: controller.settings.manualMACAddress)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    Image("VizioMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Control your Vizio TV")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("VizioControl talks directly to a compatible SmartCast TV on this Wi-Fi network. Pairing credentials stay in this iPhone’s Keychain.")
                        .font(.body)
                        .foregroundStyle(Color.vizioMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 22)

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(
                        title: "Find your TV",
                        detail: "Automatic discovery is best. A private LAN hostname or IP can help when the TV does not advertise itself."
                    )
                    TextField("Private hostname or IP (optional)", text: $manualAddress)
                        .vizioField()
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .accessibilityLabel("Manual TV hostname or IP")
                        .accessibilityHint("Optional rediscovery hint on your private network")
                    TextField("TV MAC address for Wake (optional)", text: $wakeMAC)
                        .vizioField()
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(findTVs)
                        .accessibilityLabel("TV MAC address")
                        .accessibilityHint("Optional unicast address used to wake the TV")

                    if isPreparingDiscovery || controller.isDiscovering {
                        discoveryProgress
                        Button("Cancel") {
                            controller.cancelDiscovery()
                            isPreparingDiscovery = false
                        }
                        .buttonStyle(QuietButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityHint("Stops the current TV scan")
                    } else {
                        AsyncActionButton(
                            title: "Find TVs",
                            systemImage: "dot.radiowaves.left.and.right",
                            kind: .primary,
                            action: prepareAndDiscover
                        )
                    }

                    if controller.discoveryProgress == .denied {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Local Network access is off. Allow VizioControl to find and control TVs on this Wi-Fi network.")
                                .font(.subheadline)
                                .foregroundStyle(Color.vizioText)
                            Button {
                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                            } label: {
                                Label("Open Settings", systemImage: "gear")
                            }
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityHint("Opens this app’s iOS settings")
                        }
                    }
                }
                .vizioPanel()

                if !controller.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(
                            title: "Verified TVs",
                            detail: "Each result answered on the SmartCast control port and presented a certificate."
                        )
                        ForEach(controller.candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                    .vizioPanel()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("LAN only", systemImage: "wifi")
                        .font(.headline)
                        .foregroundStyle(Color.vizioMossStrong)
                    Text("Your TV and iPhone must be on the same private network. No cloud account, desktop companion, or screen stream is used.")
                        .font(.footnote)
                        .foregroundStyle(Color.vizioMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .vizioPanel()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showPIN, onDismiss: cancelUnfinishedPairing) {
            PairingPINView(controller: controller)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var discoveryProgress: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.vizioMossStrong)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.discoveryProgress == .waitingForPermission
                     ? "Waiting for Local Network access…"
                     : "Scanning for verified TVs…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.vizioText)
                Text("Keep VizioControl open while nearby TVs respond.")
                    .font(.caption)
                    .foregroundStyle(Color.vizioMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func candidateRow(_ candidate: DeviceCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Color.vizioMossStrong)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name.isEmpty ? "Vizio TV" : candidate.name)
                        .font(.headline)
                    Text([candidate.model, candidate.endpoint.host]
                        .compactMap { value in
                            guard let value, !value.isEmpty else { return nil }
                            return value
                        }
                        .joined(separator: " • "))
                        .font(.subheadline)
                        .foregroundStyle(Color.vizioMuted)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
            }
            AsyncActionButton(
                title: "Pair",
                systemImage: "link",
                kind: .control,
                disabled: controller.isPairing,
                accessibilityHint: "Starts PIN pairing with \(candidate.name)",
                action: {
                    try await controller.pairStart(candidate)
                    showPIN = true
                }
            )
        }
        .padding(14)
        .background(Color.vizioRaised)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func findTVs() {
        guard !isPreparingDiscovery, !controller.isDiscovering else { return }
        isPreparingDiscovery = true
        Task { @MainActor in
            await prepareAndDiscoverIgnoringError()
        }
    }

    private func prepareAndDiscover() async throws {
        isPreparingDiscovery = true
        defer { isPreparingDiscovery = false }
        try await controller.saveManualEndpoint(manualAddress)
        try await controller.saveWakeMAC(wakeMAC)
        controller.clearSuccessStatus()
        guard !Task.isCancelled else { throw CancellationError() }
        await controller.discover()
    }

    private func prepareAndDiscoverIgnoringError() async {
        do { try await prepareAndDiscover() } catch { }
    }

    private func cancelUnfinishedPairing() {
        if controller.pairedDevice == nil { controller.cancelPairing() }
    }
}

private struct PairingPINView: View {
    @Bindable var controller: RemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(
                    title: "Enter the TV PIN",
                    detail: "Type the four digits shown on \(controller.pairing?.candidate.name ?? "your TV"). Two wrong attempts expire this pairing session."
                )
                TextField("4-digit PIN", text: $pin)
                    .vizioField()
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .onChange(of: pin) { _, value in
                        pin = String(value.filter(\.isNumber).prefix(4))
                    }
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .accessibilityLabel("Four-digit TV PIN")
                AsyncActionButton(
                    title: "Finish Pairing",
                    systemImage: "checkmark.shield",
                    kind: .primary,
                    disabled: pin.count != 4 || isSubmitting,
                    action: finishPairing
                )
                Text("The PIN authorizes this iPhone. VizioControl stores only the resulting token in the protected Keychain.")
                    .font(.footnote)
                    .foregroundStyle(Color.vizioMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(20)
            .background(Color.vizioGround.ignoresSafeArea())
            .navigationTitle("Pair TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.cancelPairing()
                        dismiss()
                    }
                    .minimumControlSize()
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .safeAreaInset(edge: .top, spacing: 8) {
            if let error = controller.errorBanner {
                ErrorBanner(message: error, dismiss: controller.dismissError)
            }
        }
    }

    private func submit() {
        guard pin.count == 4, !isSubmitting else { return }
        Task { @MainActor in
            do { try await finishPairing() } catch { }
        }
    }

    private func finishPairing() async throws {
        isSubmitting = true
        defer { isSubmitting = false }
        _ = try await controller.pairFinish(pin: pin)
        dismiss()
    }
}
