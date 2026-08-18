import SwiftUI

struct MacrosView: View {
    @Bindable var controller: RemoteController
    @State private var editorPresentation: MacroEditorPresentation?
    @State private var canUndoDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Macros",
                detail: controller.macros.isEmpty
                    ? "Build an ordered sequence of remote steps."
                    : "Tap a card to run it. Use the menu to edit its steps."
            )
            if let progress = controller.macroRunProgress {
                MacroRunProgressPanel(controller: controller, progress: progress)
            }


            Button {
                presentEditor(macroID: nil)
            } label: {
                Label("Create Macro", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(controller.isRunningMacro)
            .accessibilityHint("Opens the visual macro builder")
            .accessibilityIdentifier("macro.create")

            if controller.macros.isEmpty {
                Label("No macros yet", systemImage: "rectangle.stack")
                    .font(.subheadline)
                    .foregroundStyle(Color.vizioMuted)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .accessibilityElement(children: .combine)
            } else {
                ForEach(controller.macros) { macro in
                    HStack(spacing: 9) {
                        MacroRunButton(controller: controller, macro: macro)
                        Button {
                            presentEditor(macroID: macro.id)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 48, height: 48)
                                .background(Color.vizioRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .foregroundStyle(Color.vizioText)
                        .disabled(controller.isRunningMacro)
                        .accessibilityLabel("Edit \(macro.name)")
                        .accessibilityHint("Edits, reorders, duplicates, or deletes this macro")
                    }
                }
            }

            if canUndoDelete {
                AsyncActionButton(
                    title: "Undo last deletion",
                    systemImage: "arrow.uturn.backward",
                    kind: .quiet,
                    disabled: controller.isRunningMacro,
                    action: {
                        try await controller.undoDeleteMacro()
                        canUndoDelete = false
                    }
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .vizioPanel()
        .sheet(item: $editorPresentation) { presentation in
            MacroEditor(
                controller: controller,
                macroID: presentation.macroID,
                onDeleted: { canUndoDelete = true }
            )
        }
    }

    private func presentEditor(macroID: UUID?) {
        controller.clearSuccessStatus()
        editorPresentation = MacroEditorPresentation(macroID: macroID)
    }
}

private struct MacroEditorPresentation: Identifiable {
    let id = UUID()
    let macroID: UUID?
}

private struct MacroRunButton: View {
    @Bindable var controller: RemoteController
    let macro: SavedMacro
    @State private var isRunning = false

    private var summary: String {
        macroSequencePreview(macro.actions, maximumVisibleSteps: 2)
    }

    private var accessibilitySummary: String {
        macroSequenceSummary(macro.actions)
    }

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task { @MainActor in
                defer { isRunning = false }
                do { _ = try await controller.runMacro(id: macro.id) } catch { }
            }
        } label: {
            HStack(spacing: 12) {
                if isRunning {
                    ProgressView()
                        .tint(Color.vizioMossStrong)
                } else {
                    Image(
                        systemName: macro.actions.first.map(macroActionSystemImage)
                            ?? "rectangle.stack.fill"
                    )
                    .foregroundStyle(Color.vizioMossStrong)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(macro.name)
                        .font(.headline)
                        .foregroundStyle(Color.vizioText)
                        .lineLimit(2)
                    Text(summary.isEmpty ? "No steps" : summary)
                        .font(.caption)
                        .foregroundStyle(Color.vizioMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text("Runs \(macro.usageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.vizioMuted)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.vizioRaised)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning || controller.isRunningMacro)
        .accessibilityLabel(macro.name)
        .accessibilityValue(accessibilitySummary)
    }
}

private struct MacroRunProgressPanel: View {
    @Bindable var controller: RemoteController
    let progress: MacroRunProgress

    private var operationTitle: String {
        progress.macroID == nil ? "Testing \(progress.name)" : "Running \(progress.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(operationTitle)
                .font(.headline)
                .foregroundStyle(Color.vizioText)
                .lineLimit(2)
            Text(
                "Step \(progress.currentStep) of \(progress.totalSteps) · \(macroActionTitle(progress.action))"
            )
            .font(.subheadline)
            .foregroundStyle(Color.vizioMuted)
            .fixedSize(horizontal: false, vertical: true)
            ProgressView(
                value: Double(progress.currentStep),
                total: Double(progress.totalSteps)
            )
            .tint(Color.vizioMossStrong)
            Button {
                controller.cancelMacro()
            } label: {
                Label("Cancel Run", systemImage: "stop.fill")
            }
            .buttonStyle(ControlButtonStyle())
            .accessibilityHint("Stops before the next macro step")
            .accessibilityIdentifier("macro.cancelRun")
        }
        .padding(12)
        .background(Color.vizioRaised)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityIdentifier("macro.runProgress")
    }
}

private struct MacroStepDraft: Identifiable {
    let id: UUID
    var action: TVAction

    init(id: UUID = UUID(), action: TVAction) {
        self.id = id
        self.action = action
    }
}

private struct MacroEditor: View {
    @Bindable var controller: RemoteController
    let macroID: UUID?
    let onDeleted: @MainActor () -> Void
    private let initialName: String
    private let initialActions: [TVAction]

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var steps: [MacroStepDraft]
    @State private var showStepPicker = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var isTesting = false

    init(
        controller: RemoteController,
        macroID: UUID?,
        onDeleted: @escaping @MainActor () -> Void
    ) {
        self.controller = controller
        self.macroID = macroID
        self.onDeleted = onDeleted
        let macro = macroID.flatMap { id in controller.macros.first { $0.id == id } }
        let initialName = macro?.name ?? ""
        let initialActions = macro?.actions ?? []
        self.initialName = initialName
        self.initialActions = initialActions
        _name = State(initialValue: initialName)
        _steps = State(
            initialValue: initialActions.map { MacroStepDraft(action: $0) }
        )
    }

    private var macro: SavedMacro? {
        guard let macroID else { return nil }
        return controller.macros.first { $0.id == macroID }
    }

    private var macroIndex: Int? {
        guard let macroID else { return nil }
        return controller.macros.firstIndex { $0.id == macroID }
    }

    private var isEditing: Bool {
        macroID != nil
    }

    private var draftCannotRun: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || steps.isEmpty
            || steps.count > MacroConstraints.maximumStepCount
    }

    private var isDirty: Bool {
        guard name == initialName, steps.count == initialActions.count else { return true }
        return zip(steps, initialActions).contains { draft, action in
            draft.action != action
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    namePanel
                    stepsPanel
                    testAndSavePanel
                    if isEditing {
                        macroManagementPanel
                        deletePanel
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.vizioGround.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Macro" : "Create Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: requestDismiss)
                        .disabled(isTesting)
                        .accessibilityIdentifier("macro.editor.cancel")
                }
            }
        }
        .interactiveDismissDisabled(isTesting || isDirty)
        .sheet(isPresented: $showStepPicker) {
            MacroStepPicker(currentVolume: controller.tvState.volume) { action in
                guard steps.count < MacroConstraints.maximumStepCount else { return }
                steps.append(MacroStepDraft(action: action))
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
            "Delete \(macro?.name ?? "this macro")?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Macro", role: .destructive) {
                guard let macroID else { return }
                Task { @MainActor in
                    do {
                        try await controller.deleteMacro(id: macroID)
                        onDeleted()
                        dismiss()
                    } catch { }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Deleting this macro does not control the TV. One deletion can be undone.")
        }
        .alert("Discard changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your macro name and step changes have not been saved.")
        }
    }

    private var namePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                title: "Macro name",
                detail: "Use a short name that describes the whole sequence."
            )
            TextField("Macro name", text: $name)
                .vizioField()
                .submitLabel(.done)
                .onChange(of: name) { _, value in
                    if value.count > MacroConstraints.maximumNameLength {
                        name = String(value.prefix(MacroConstraints.maximumNameLength))
                    }
                }
                .accessibilityLabel("Macro name")
                .accessibilityIdentifier("macro.name")
            Text("\(name.count)/\(MacroConstraints.maximumNameLength)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.vizioMuted)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(
                    "\(name.count) of \(MacroConstraints.maximumNameLength) characters"
                )
        }
        .vizioPanel()
        .disabled(controller.isRunningMacro)
    }

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Steps",
                detail: steps.isEmpty
                    ? "Add at least one remote action or wait."
                    : macroSequencePreview(steps.map(\.action))
            )
            if !steps.isEmpty {
                Text(
                    steps.count == MacroConstraints.maximumStepCount
                        ? "\(steps.count) of \(MacroConstraints.maximumStepCount) steps · Limit reached"
                        : "\(steps.count) of \(MacroConstraints.maximumStepCount) steps"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.vizioMuted)
                .accessibilityLabel(
                    "\(steps.count) of \(MacroConstraints.maximumStepCount) macro steps"
                )
            }

            if steps.isEmpty {
                Label("No steps yet", systemImage: "list.number")
                    .font(.subheadline)
                    .foregroundStyle(Color.vizioMuted)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, draft in
                    MacroStepRow(
                        number: index + 1,
                        action: actionBinding(for: draft.id),
                        canMoveEarlier: index > 0,
                        canMoveLater: index < steps.count - 1,
                        moveEarlier: { moveStep(id: draft.id, direction: -1) },
                        moveLater: { moveStep(id: draft.id, direction: 1) },
                        delete: { deleteStep(id: draft.id) }
                    )
                    if index < steps.count - 1 {
                        Divider()
                    }
                }
            }

            Button {
                showStepPicker = true
            } label: {
                Label("Add Step", systemImage: "plus")
            }
            .buttonStyle(ControlButtonStyle())
            .accessibilityHint("Shows remote actions and wait durations")
            .accessibilityIdentifier("macro.addStep")
            .disabled(
                steps.count >= MacroConstraints.maximumStepCount || controller.isRunningMacro
            )
        }
        .vizioPanel()
        .disabled(controller.isRunningMacro)
    }

    private var testAndSavePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                title: "Test and save",
                detail: "Test runs this draft on TV. Saving stores it without controlling the TV."
            )
            if let progress = controller.macroRunProgress {
                MacroRunProgressPanel(controller: controller, progress: progress)
            }
            AsyncActionButton(
                title: "Test Steps",
                systemImage: "play.fill",
                disabled: draftCannotRun || controller.isRunningMacro,
                accessibilityHint: "Runs this draft without saving or changing run counts",
                action: testSteps
            )
            .accessibilityIdentifier("macro.test")
            AsyncActionButton(
                title: isEditing ? "Update Macro" : "Save Macro",
                systemImage: "checkmark",
                kind: .primary,
                disabled: draftCannotRun || controller.isRunningMacro,
                accessibilityHint: "Saves this macro without controlling the TV",
                action: saveMacro
            )
            .accessibilityIdentifier("macro.save")
        }
        .vizioPanel()
    }

    private var macroManagementPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Macro order and copies")
            AsyncActionButton(
                title: "Move Earlier",
                systemImage: "arrow.up",
                disabled: controller.isRunningMacro || macroIndex == 0,
                action: {
                    guard let macroID else { return }
                    try await controller.reorderMacro(id: macroID, direction: -1)
                }
            )
            AsyncActionButton(
                title: "Move Later",
                systemImage: "arrow.down",
                disabled: controller.isRunningMacro
                    || macroIndex == nil
                    || macroIndex == controller.macros.count - 1,
                action: {
                    guard let macroID else { return }
                    try await controller.reorderMacro(id: macroID, direction: 1)
                }
            )
            AsyncActionButton(
                title: "Duplicate",
                systemImage: "plus.square.on.square",
                disabled: controller.isRunningMacro,
                accessibilityHint: "Appends a copy and keeps this editor open",
                action: {
                    guard let macroID else { return }
                    try await controller.duplicateMacro(id: macroID)
                }
            )
        }
        .vizioPanel()
    }

    private var deletePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                title: "Delete macro",
                detail: "Deleting does not send anything to TV. One deletion can be undone from the remote."
            )
            Button {
                confirmDelete = true
            } label: {
                Label("Delete Macro", systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(controller.isRunningMacro)
        }
        .vizioPanel()
    }

    private func requestDismiss() {
        if isDirty {
            confirmDiscard = true
        } else {
            dismiss()
        }
    }

    private func actionBinding(for id: UUID) -> Binding<TVAction> {
        Binding(
            get: {
                steps.first(where: { $0.id == id })?.action ?? .wait(milliseconds: 250)
            },
            set: { action in
                guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
                steps[index].action = action
            }
        )
    }

    private func moveStep(id: UUID, direction: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }

    private func deleteStep(id: UUID) {
        steps.removeAll { $0.id == id }
    }

    @MainActor
    private func testSteps() async throws {
        isTesting = true
        defer { isTesting = false }
        try await controller.testMacro(name: name, actions: steps.map(\.action))
    }

    @MainActor
    private func saveMacro() async throws {
        let actions = steps.map(\.action)
        if let macroID {
            _ = try await controller.updateMacro(id: macroID, name: name, actions: actions)
        } else {
            _ = try await controller.createMacro(name: name, actions: actions)
        }
        dismiss()
    }
}

private struct MacroStepRow: View {
    let number: Int
    @Binding var action: TVAction
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let moveEarlier: () -> Void
    let moveLater: () -> Void
    let delete: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.vizioMuted)
                    .frame(minWidth: 28, alignment: .trailing)
                Image(systemName: macroActionSystemImage(action))
                    .foregroundStyle(Color.vizioMossStrong)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(macroActionTitle(action))
                    .font(.headline)
                    .foregroundStyle(Color.vizioText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(number), \(macroActionTitle(action))")

            actionEditor

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    earlierControl(title: "Move Earlier")
                    laterControl(title: "Move Later")
                    deleteControl(title: "Delete Step")
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        earlierControl(title: "Earlier")
                        laterControl(title: "Later")
                        deleteControl(title: "Delete")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            earlierControl(title: "Earlier")
                            laterControl(title: "Later")
                        }
                        deleteControl(title: "Delete")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionEditor: some View {
        switch action {
        case let .key(key, count):
            Stepper(
                "Repeat \(count)",
                value: Binding(
                    get: {
                        guard case let .key(_, currentCount) = action else { return count }
                        return currentCount
                    },
                    set: { action = .key(key, count: $0) }
                ),
                in: 1...10
            )
            .accessibilityLabel("Repeat count")
            .accessibilityValue("\(count)")
        case let .setVolume(volume):
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1.fill")
                    .foregroundStyle(Color.vizioMuted)
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: {
                            guard case let .setVolume(currentVolume) = action else {
                                return Double(volume)
                            }
                            return Double(currentVolume)
                        },
                        set: { action = .setVolume(Int($0.rounded())) }
                    ),
                    in: 0...100,
                    step: 1
                )
                .accessibilityLabel("Set volume")
                .accessibilityValue("\(volume) percent")
                Text("\(volume)")
                    .font(.body.monospacedDigit().bold())
                    .frame(minWidth: 32, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        case .launchApp:
            EmptyView()
        case let .wait(milliseconds):
            Picker(
                "Wait duration",
                selection: Binding(
                    get: {
                        guard case let .wait(currentMilliseconds) = action else {
                            return milliseconds
                        }
                        return currentMilliseconds
                    },
                    set: { action = .wait(milliseconds: $0) }
                )
            ) {
                ForEach(MacroDefinitionValidator.waitPresets, id: \.self) { preset in
                    Text(macroActionTitle(.wait(milliseconds: preset)))
                        .tag(preset)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func earlierControl(title: String) -> some View {
        MacroStepControlButton(
            title: title,
            accessibilityTitle: "Move Earlier",
            systemImage: "arrow.up",
            disabled: !canMoveEarlier,
            action: moveEarlier
        )
    }

    private func laterControl(title: String) -> some View {
        MacroStepControlButton(
            title: title,
            accessibilityTitle: "Move Later",
            systemImage: "arrow.down",
            disabled: !canMoveLater,
            action: moveLater
        )
    }

    private func deleteControl(title: String) -> some View {
        MacroStepControlButton(
            title: title,
            accessibilityTitle: "Delete Step",
            systemImage: "trash",
            destructive: true,
            action: delete
        )
    }
}

private struct MacroStepControlButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let accessibilityTitle: String
    let systemImage: String
    var disabled = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(accessibilityTitle)
    }
}

private struct MacroStepOption: Identifiable {
    let id: String
    let displayTitle: String
    let action: TVAction
}

private struct MacroStepPicker: View {
    @Environment(\.dismiss) private var dismiss
    let currentVolume: Int?
    let onAdd: @MainActor (TVAction) -> Void
    private let catalog = AppCatalog()
    private let columns = [GridItem(.adaptive(minimum: 144), spacing: 9)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    optionPanel(title: "Navigation", options: navigationOptions)
                    optionPanel(title: "Playback", options: playbackOptions)
                    optionPanel(title: "Audio", options: audioOptions)
                    optionPanel(title: "Power", options: powerOptions)
                    optionPanel(title: "Apps", options: appOptions)
                    optionPanel(title: "Timing", options: timingOptions)
                }
                .padding(16)
            }
            .background(Color.vizioGround.ignoresSafeArea())
            .navigationTitle("Add Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func optionPanel(title: String, options: [MacroStepOption]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: title)
            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(options) { option in
                    Button {
                        onAdd(option.action)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: macroActionSystemImage(option.action))
                                .accessibilityHidden(true)
                            Text(option.displayTitle)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ControlButtonStyle())
                    .accessibilityLabel("Add \(macroActionTitle(option.action))")
                    .accessibilityIdentifier("macro.step.\(option.id)")
                }
            }
        }
        .vizioPanel()
    }

    private var navigationOptions: [MacroStepOption] {
        [
            option("navigation.up", .key(.up, count: 1)),
            option("navigation.down", .key(.down, count: 1)),
            option("navigation.left", .key(.left, count: 1)),
            option("navigation.right", .key(.right, count: 1)),
            MacroStepOption(
                id: "navigation.ok",
                displayTitle: "OK / Select",
                action: .key(.ok, count: 1)
            ),
            option("navigation.back", .key(.back, count: 1)),
            option("navigation.home", .key(.home, count: 1)),
            option("navigation.menu", .key(.menu, count: 1)),
            option("navigation.exit", .key(.exit, count: 1)),
            option("navigation.input", .key(.input, count: 1)),
        ]
    }

    private var playbackOptions: [MacroStepOption] {
        [
            option("playback.play", .key(.play, count: 1)),
            option("playback.pause", .key(.pause, count: 1)),
            option("playback.rewind", .key(.rewind, count: 1)),
            option("playback.fast-forward", .key(.fastForward, count: 1)),
        ]
    }

    private var audioOptions: [MacroStepOption] {
        let volume = min(100, max(0, currentVolume ?? 20))
        return [
            option("audio.volume-up", .key(.volumeUp, count: 1)),
            option("audio.volume-down", .key(.volumeDown, count: 1)),
            option("audio.mute", .key(.mute, count: 1)),
            option("audio.set-volume", .setVolume(volume)),
        ]
    }

    private var powerOptions: [MacroStepOption] {
        [
            option("power.on", .key(.powerOn, count: 1)),
            option("power.standby", .key(.powerOff, count: 1)),
            option("power.toggle", .key(.powerToggle, count: 1)),
        ]
    }

    private var appOptions: [MacroStepOption] {
        catalog.configurations.map { configuration in
            option(
                "app.\(configuration.appID).\(configuration.namespace)",
                .launchApp(configuration.name)
            )
        }
    }

    private var timingOptions: [MacroStepOption] {
        MacroDefinitionValidator.waitPresets.map { milliseconds in
            option("timing.\(milliseconds)", .wait(milliseconds: milliseconds))
        }
    }

    private func option(_ id: String, _ action: TVAction) -> MacroStepOption {
        MacroStepOption(id: id, displayTitle: macroActionTitle(action), action: action)
    }
}
