import SwiftUI

struct RootView: View {
    @State private var controller: RemoteController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: RemoteController = RemoteController()) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        ZStack {
            Color.vizioGround.ignoresSafeArea()
            Group {
                if controller.isLoading {
                    LoadingView()
                } else if controller.pairedDevice == nil {
                    OnboardingView(controller: controller)
                } else {
                    RemoteView(controller: controller)
                }
            }
            .transition(reduceMotion ? .identity : .opacity)
        }
        .foregroundStyle(Color.vizioText)
        .tint(Color.vizioMossStrong)
        .safeAreaInset(edge: .top, spacing: 8) {
            if let error = controller.errorBanner {
                ErrorBanner(message: error, dismiss: controller.dismissError)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if let status = controller.successStatus {
                SuccessBanner(message: status, dismiss: controller.clearSuccessStatus)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.isLoading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.pairedDevice?.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.errorBanner)
        .task {
            await controller.initialize()
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await controller.handleScenePhase(phase.appSceneActivity) }
        }
    }
}

private extension ScenePhase {
    var appSceneActivity: AppSceneActivity {
        switch self {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
}
