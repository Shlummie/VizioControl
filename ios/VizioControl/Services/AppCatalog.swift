import Foundation

public protocol AppCataloging: Sendable {
    var configurations: [AppLaunchConfiguration] { get }
    func resolve(_ nameOrID: String) throws -> AppLaunchConfiguration
}

public struct AppCatalog: AppCataloging, Sendable {
    public let configurations: [AppLaunchConfiguration]

    public init() {
        configurations = [
            AppLaunchConfiguration(appID: "3", namespace: 2, message: "", name: "Hulu"),
            AppLaunchConfiguration(appID: "1", namespace: 5, message: "", name: "YouTube"),
            AppLaunchConfiguration(appID: "1", namespace: 3, message: "", name: "Netflix"),
        ]
    }

    public func resolve(_ nameOrID: String) throws -> AppLaunchConfiguration {
        let query = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            throw VizioControlError.message("Enter an app name.")
        }
        if let exact = configurations.first(where: { $0.name.lowercased() == query }) {
            return exact
        }
        if let partial = configurations.first(where: { $0.name.lowercased().contains(query) }) {
            return partial
        }
        throw VizioControlError.message(
            "The local quick launcher does not contain “\(nameOrID)”. Use SmartCast Home to open it manually."
        )
    }
}
