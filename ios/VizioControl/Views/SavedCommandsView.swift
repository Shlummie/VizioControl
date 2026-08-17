import SwiftUI

struct SavedCommandsView: View {
    @Bindable var controller: RemoteController
    @State private var editingCommand: SavedCommand?
    @State private var canUndoDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Saved local commands",
                detail: controller.commands.isEmpty
                    ? "Successful commands appear here for one-tap replay."
                    : "Tap a card to run it. Edit changes only its local label and order."
            )

            if controller.commands.isEmpty {
                Label("No saved commands yet", systemImage: "rectangle.stack")
                    .font(.subheadline)
                    .foregroundStyle(Color.vizioMuted)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .accessibilityElement(children: .combine)
            } else {
                ForEach(controller.commands) { command in
                    HStack(spacing: 9) {
                        SavedCommandRunButton(controller: controller, command: command)
                        Button {
                            editingCommand = command
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 48, height: 48)
                                .background(Color.vizioRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .foregroundStyle(Color.vizioText)
                        .accessibilityLabel("Edit \(command.label)")
                        .accessibilityHint("Rename, reorder, duplicate, or delete this command")
                    }
                }
            }

            if canUndoDelete {
                AsyncActionButton(
                    title: "Undo last deletion",
                    systemImage: "arrow.uturn.backward",
                    kind: .quiet,
                    action: {
                        try await controller.undoDeleteCommand()
                        canUndoDelete = false
                    }
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .vizioPanel()
        .sheet(item: $editingCommand) { command in
            SavedCommandEditor(
                controller: controller,
                commandID: command.id,
                onDeleted: { canUndoDelete = true }
            )
        }
    }
}

private struct SavedCommandRunButton: View {
    @Bindable var controller: RemoteController
    let command: SavedCommand
    @State private var isRunning = false

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task { @MainActor in
                defer { isRunning = false }
                do { _ = try await controller.runSavedCommand(id: command.id) } catch { }
            }
        } label: {
            HStack(spacing: 12) {
                if isRunning {
                    ProgressView().tint(Color.vizioMossStrong)
                } else {
                    Image(systemName: command.systemImage)
                        .foregroundStyle(Color.vizioMossStrong)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.label)
                        .font(.headline)
                        .foregroundStyle(Color.vizioText)
                        .lineLimit(1)
                    Text(command.normalizedRequest)
                        .font(.caption)
                        .foregroundStyle(Color.vizioMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(command.usageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.vizioMuted)
                    .accessibilityLabel("Run count \(command.usageCount)")
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.vizioRaised)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .accessibilityLabel(command.label)
        .accessibilityValue(command.normalizedRequest)
        .accessibilityHint("Runs this saved command on TV")
    }
}

private struct SavedCommandEditor: View {
    @Bindable var controller: RemoteController
    let commandID: UUID
    let onDeleted: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var confirmDelete = false

    private var command: SavedCommand? {
        controller.commands.first { $0.id == commandID }
    }

    private var commandIndex: Int? {
        controller.commands.firstIndex { $0.id == commandID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(
                            title: "Card label",
                            detail: command?.normalizedRequest
                        )
                        TextField("Command label", text: $label)
                            .vizioField()
                            .submitLabel(.done)
                            .onSubmit(saveLabel)
                            .accessibilityLabel("Saved command label")
                        AsyncActionButton(
                            title: "Save Label",
                            systemImage: "checkmark",
                            kind: .primary,
                            disabled: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            action: {
                                try await controller.editCommand(id: commandID, label: label)
                                dismiss()
                            }
                        )
                    }
                    .vizioPanel()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "Order and copies")
                        HStack(spacing: 9) {
                            AsyncActionButton(
                                title: "Move Earlier",
                                systemImage: "arrow.up",
                                disabled: commandIndex == 0,
                                action: { try await controller.reorderCommand(id: commandID, direction: -1) }
                            )
                            AsyncActionButton(
                                title: "Move Later",
                                systemImage: "arrow.down",
                                disabled: commandIndex == nil || commandIndex == controller.commands.count - 1,
                                action: { try await controller.reorderCommand(id: commandID, direction: 1) }
                            )
                        }
                        AsyncActionButton(
                            title: "Duplicate",
                            systemImage: "plus.square.on.square",
                            action: { try await controller.duplicateCommand(id: commandID) }
                        )
                    }
                    .vizioPanel()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(
                            title: "Delete card",
                            detail: "Deleting this card does not send anything to TV. One deletion can be undone from the remote."
                        )
                        Button {
                            confirmDelete = true
                        } label: {
                            Label("Delete Saved Command", systemImage: "trash")
                        }
                        .buttonStyle(DangerButtonStyle())
                    }
                    .vizioPanel()
                }
                .padding(16)
            }
            .background(Color.vizioGround.ignoresSafeArea())
            .navigationTitle("Edit Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .minimumControlSize()
                }
            }
        }
        .onAppear { label = command?.label ?? "" }
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
            "Delete \(command?.label ?? "this command")?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Command", role: .destructive) {
                Task { @MainActor in
                    do {
                        try await controller.deleteCommand(id: commandID)
                        onDeleted()
                        dismiss()
                    } catch { }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func saveLabel() {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            do {
                try await controller.editCommand(id: commandID, label: label)
                dismiss()
            } catch { }
        }
    }
}
