import Foundation

/// Marketing version lives in Xcode (`MARKETING_VERSION`).
/// Bump `updatedDisplay` whenever you ship a visible release.
enum AppBuildInfo {
    static let updatedDisplay = "Nov 11, 2026"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
    }

    static var footerText: String {
        "v\(version) · Updated \(updatedDisplay)"
    }
}
