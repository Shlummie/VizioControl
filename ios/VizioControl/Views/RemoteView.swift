import SwiftUI

private enum RemotePage: Hashable {
    case remote
    case macros
}

struct RemoteView: View {
    @Bindable var controller: RemoteController
    @State private var showSettings = false
    @State private var selectedPage: RemotePage = .remote
    @State private var tvText = ""
    @State private var volume = 0.0
    @State private var isSettingVolume = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let navigationColumns = [GridItem(.adaptive(minimum: 88), spacing: 9)]
    private let playbackColumns = [GridItem(.adaptive(minimum: 68), spacing: 9)]
    private let dPadColumns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 3)

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedPage) {
                remotePage
                    .tag(RemotePage.remote)
                macrosPage
                    .tag(RemotePage.macros)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                pageTabs
            }
            .background(Color.vizioGround.ignoresSafeArea())
            .navigationTitle("VizioControl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .minimumControlSize()
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityHint("Shows TV identity, network fallbacks, and forget controls")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(controller: controller)
        }
        .onAppear(perform: synchronizeVolume)
        .onChange(of: controller.tvState.volume) { _, _ in synchronizeVolume() }
    }

    private var remotePage: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusPanel
                Group {
                    powerPanel
                    navigationPanel
                    dPadPanel
                    playbackPanel
                    volumePanel
                    appsPanel
                    textPanel
                }
                .disabled(controller.isRunningMacro)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.vizioGround.ignoresSafeArea())
        .accessibilityIdentifier("remote.page.controls")
    }

    private var macrosPage: some View {
        ScrollView {
            MacrosView(controller: controller)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(Color.vizioGround.ignoresSafeArea())
        .accessibilityIdentifier("remote.page.macros")
    }

    private var pageTabs: some View {
        HStack(spacing: 8) {
            pageTab(
                .remote,
                title: "Remote",
                systemImage: "dpad.fill",
                accessibilityHint: "Shows TV remote controls"
            )
            pageTab(
                .macros,
                title: "Macros",
                systemImage: "rectangle.stack.fill",
                accessibilityHint: "Shows saved macro buttons"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.vizioSurface)
        .overlay(alignment: .top) {
            Color.vizioRaised.frame(height: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedPage)
    }

    private func pageTab(
        _ page: RemotePage,
        title: String,
        systemImage: String,
        accessibilityHint: String
    ) -> some View {
        let isSelected = selectedPage == page
        return Button {
            if reduceMotion {
                selectedPage = page
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedPage = page
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.vizioMossStrong : Color.vizioMuted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isSelected ? Color.vizioRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) tab")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(page == .remote ? "remote.tab.remote" : "remote.tab.macros")
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    statusIdentity
                    refreshButton
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    statusIdentity
                    Spacer(minLength: 8)
                    refreshButton.fixedSize(horizontal: true, vertical: false)
                }
            }
            if let currentApp = controller.tvState.currentApp, !currentApp.isEmpty {
                VizioInfoRow(label: "Current app", value: currentApp)
            }
            if let volume = controller.tvState.volume {
                VizioInfoRow(label: "TV volume", value: "\(volume)\(controller.tvState.muted == true ? " • Muted" : "")")
            }
        }
        .vizioPanel()
        .accessibilityElement(children: .contain)
    }

    private var powerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Power",
                detail: powerDetail
            )
            AsyncActionButton(
                title: powerTitle,
                systemImage: powerSystemImage,
                kind: .primary,
                accessibilityHint: powerAccessibilityHint,
                action: { _ = try await controller.press(powerKey) }
            )
            if controller.isWaking {
                Label("Waking TV and waiting for network controls…", systemImage: "wake")
                    .font(.subheadline)
                    .foregroundStyle(Color.vizioMuted)
                    .accessibilityElement(children: .combine)
            }
        }
        .vizioPanel()
    }

    private var navigationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "TV navigation")
            LazyVGrid(columns: navigationColumns, spacing: 9) {
                remoteKey("Input", image: "cable.connector", key: .input)
                remoteKey("Home", image: "house.fill", key: .home)
                remoteKey("Back", image: "arrow.uturn.backward", key: .back)
                remoteKey("Menu", image: "line.3.horizontal", key: .menu)
                remoteKey("Exit", image: "rectangle.portrait.and.arrow.right", key: .exit)
            }
        }
        .vizioPanel()
    }

    private var dPadPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Directional pad",
                detail: "Five separate controls prevent accidental neighboring presses."
            )
            LazyVGrid(columns: dPadColumns, spacing: 9) {
                dPadSpacer
                remoteKey("Up", image: "chevron.up", key: .up, symbolOnly: true)
                dPadSpacer
                remoteKey("Left", image: "chevron.left", key: .left, symbolOnly: true)
                remoteKey("OK", image: "circle.inset.filled", key: .ok, symbolOnly: true)
                remoteKey("Right", image: "chevron.right", key: .right, symbolOnly: true)
                dPadSpacer
                remoteKey("Down", image: "chevron.down", key: .down, symbolOnly: true)
                dPadSpacer
            }
        }
        .vizioPanel()
    }

    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Playback")
            LazyVGrid(columns: playbackColumns, spacing: 9) {
                remoteKey("Rewind", image: "backward.fill", key: .rewind, symbolOnly: true)
                remoteKey("Play", image: "play.fill", key: .play, symbolOnly: true)
                remoteKey("Pause", image: "pause.fill", key: .pause, symbolOnly: true)
                remoteKey("Fast Forward", image: "forward.fill", key: .fastForward, symbolOnly: true)
            }
        }
        .vizioPanel()
    }

    private var volumePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Volume")
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1.fill")
                    .foregroundStyle(Color.vizioMuted)
                    .accessibilityHidden(true)
                Slider(value: $volume, in: 0...100, step: 1) { editing in
                    guard !editing else { return }
                    isSettingVolume = true
                    Task { @MainActor in
                        defer { isSettingVolume = false }
                        do { _ = try await controller.setVolume(volume) } catch { }
                    }
                }
                .accessibilityLabel("TV volume")
                .accessibilityValue("\(Int(volume)) percent")
                Text("\(Int(volume))")
                    .font(.body.monospacedDigit().bold())
                    .frame(minWidth: 32, alignment: .trailing)
                    .accessibilityHidden(true)
                if isSettingVolume {
                    ProgressView()
                        .tint(Color.vizioMossStrong)
                        .accessibilityLabel("Setting TV volume")
                }
            }
            AsyncActionButton(
                title: controller.tvState.muted == true ? "Unmute" : "Mute",
                systemImage: controller.tvState.muted == true ? "speaker.wave.2.fill" : "speaker.slash.fill",
                action: { _ = try await controller.press(.mute) }
            )
        }
        .vizioPanel()
    }

    private var appsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Quick apps",
                detail: "Offline launch values verified against Vizio’s SmartCast catalog."
            )
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 9) {
                    quickApp("Hulu")
                    quickApp("YouTube")
                    quickApp("Netflix")
                }
            } else {
                HStack(spacing: 9) {
                    quickApp("Hulu")
                    quickApp("YouTube")
                    quickApp("Netflix")
                }
            }
        }
        .vizioPanel()
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "TV text entry",
                detail: "Sends 1–120 ASCII characters to the active TV text field."
            )
            TextField("Text for TV", text: $tvText, axis: .vertical)
                .vizioField()
                .lineLimit(1...4)
                .autocorrectionDisabled()
                .onChange(of: tvText) { _, value in
                    tvText = String(value.unicodeScalars.filter(\.isASCII).prefix(120))
                }
                .submitLabel(.send)
                .onSubmit(sendTVText)
                .accessibilityLabel("Text to send to TV")
            HStack {
                Text("\(tvText.count)/120")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.vizioMuted)
                Spacer()
                AsyncActionButton(
                    title: "Send",
                    systemImage: "paperplane.fill",
                    kind: .quiet,
                    disabled: tvText.isEmpty,
                    action: sendTVTextAction
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .vizioPanel()
    }


    private func remoteKey(_ title: String, image: String, key: TVKey, symbolOnly: Bool = false) -> some View {
        AsyncActionButton(
            title: title,
            systemImage: image,
            symbolOnly: symbolOnly,
            accessibilityHint: "Sends \(title) to the TV",
            action: { _ = try await controller.press(key) }
        )
    }

    private var dPadSpacer: some View {
        Color.clear
            .frame(minHeight: 48)
            .accessibilityHidden(true)
    }

    private func quickApp(_ name: String) -> some View {
        AsyncActionButton(
            title: name,
            systemImage: "play.rectangle.fill",
            accessibilityHint: "Opens \(name) on TV",
            action: { try await controller.launchApp(name) }
        )
    }

    private var connectionLabel: String {
        guard controller.tvState.connected else { return "Offline" }
        if controller.tvState.power == false { return "Connected • TV off" }
        return "Connected"
    }

    private var powerTitle: String {
        guard controller.tvState.connected else { return "Wake" }
        return controller.tvState.power == false ? "Turn On" : "Standby"
    }

    private var powerSystemImage: String {
        controller.tvState.connected && controller.tvState.power != false ? "power" : "wake"
    }
    private var statusIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(connectionLabel, systemImage: controller.tvState.connected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(controller.tvState.connected ? Color.vizioMossStrong : Color.vizioDanger)
            Text(controller.pairedDevice?.name ?? "Vizio TV")
                .font(.title2.bold())
            Text(controller.tvState.endpoint?.host ?? controller.pairedDevice?.endpoint.host ?? "Endpoint unavailable")
                .font(.subheadline.monospaced())
                .foregroundStyle(Color.vizioMuted)
                .textSelection(.enabled)
        }
    }

    private var refreshButton: some View {
        AsyncActionButton(
            title: "Refresh",
            systemImage: "arrow.clockwise",
            kind: .quiet,
            accessibilityHint: "Checks TV state and verifies a changed network address",
            action: { _ = await controller.refreshTVState() }
        )
    }


    private var powerKey: TVKey {
        controller.tvState.connected && controller.tvState.power != false ? .powerOff : .powerOn
    }

    private var powerDetail: String {
        controller.tvState.connected && controller.tvState.power != false
            ? "Standby first verifies Quick Start so network wake remains available."
            : "Wake sends a local network magic packet and retries authenticated power-on."
    }

    private var powerAccessibilityHint: String {
        powerTitle == "Standby"
            ? "Verifies Quick Start before turning TV off"
            : "Attempts to power on the paired TV"
    }

    private func synchronizeVolume() {
        if let current = controller.tvState.volume, !isSettingVolume {
            volume = Double(current)
        }
    }

    private func sendTVText() {
        guard !tvText.isEmpty else { return }
        Task { @MainActor in
            do { try await sendTVTextAction() } catch { }
        }
    }

    private func sendTVTextAction() async throws {
        let value = tvText
        try await controller.sendText(value)
        if tvText == value { tvText = "" }
    }

}
