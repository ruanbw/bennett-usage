public struct BennettUsageCore {
    /// Fallback marketing version for executables that run outside an app
    /// bundle (tests, `swift run`). A packaged build reports the version the
    /// packaging script stamped into `CFBundleShortVersionString` instead —
    /// see `UpdateChecker.bundledVersion(bundle:)`.
    public static let version = "1.4.0"
}

import Foundation

extension Notification.Name {
    public static let bennettUsageDataDidUpdate = Notification.Name("bennettUsageDataDidUpdate")
}
