import SwiftUI

@main
struct VizioControlApp: App {
    @State private var controller: RemoteController

    init() {
        #if DEBUG
        let controller = UITestSupport.makeControllerIfRequested() ?? RemoteController()
        #else
        let controller = RemoteController()
        #endif
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
                .preferredColorScheme(.dark)
        }
    }
}
