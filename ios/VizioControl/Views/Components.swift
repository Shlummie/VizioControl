import SwiftUI

enum AsyncButtonKind {
    case primary
    case control
    case quiet
    case danger
}

struct AsyncActionButton: View {
    let title: String
    let systemImage: String
    var kind: AsyncButtonKind = .control
    var disabled = false
    var symbolOnly = false
    var accessibilityHint = ""
    let action: @MainActor () async throws -> Void

    @State private var isRunning = false

    var body: some View {
        Group {
            switch kind {
            case .primary:
                button.buttonStyle(PrimaryButtonStyle())
            case .control:
                button.buttonStyle(ControlButtonStyle())
            case .quiet:
                button.buttonStyle(QuietButtonStyle())
            case .danger:
                button.buttonStyle(DangerButtonStyle())
            }
        }
        .disabled(disabled || isRunning)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }

    private var button: some View {
        Button(role: kind == .danger ? .destructive : nil) {
            guard !isRunning else { return }
            isRunning = true
            Task { @MainActor in
                defer { isRunning = false }
                do { try await action() } catch { }
            }
        } label: {
            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .tint(kind == .primary ? Color.vizioSurface : Color.vizioMossStrong)
                } else {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                if !symbolOnly {
                    Text(title)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Color.vizioText)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.vizioMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VizioInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(Color.vizioMuted)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.vizioText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.vizioDanger)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.vizioText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Error. \(message)")
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .minimumControlSize()
            }
            .foregroundStyle(Color.vizioMuted)
            .accessibilityLabel("Dismiss error")
        }
        .padding(14)
        .background(Color.vizioRaised)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.vizioDanger).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 16)
    }
}

struct SuccessBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.vizioMossStrong)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.vizioText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Success. \(message)")
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .minimumControlSize()
            }
            .foregroundStyle(Color.vizioMuted)
            .accessibilityLabel("Dismiss status")
        }
        .padding(.horizontal, 14)
        .background(Color.vizioRaised)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 16)
    }
}

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color.vizioGround.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("VizioMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                Text("VizioControl")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.vizioText)
                ProgressView()
                    .tint(Color.vizioMoss)
                    .accessibilityLabel("Loading VizioControl")
            }
        }
    }
}
