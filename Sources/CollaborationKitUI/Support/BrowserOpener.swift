import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Opens a URL in the user's default browser.
///
/// Platform-abstracted so the OAuth paste flow can be written once. On macOS
/// this uses `NSWorkspace.shared.open`; on iOS `UIApplication.shared.open`; on
/// unsupported platforms it is a no-op that returns `false`.
enum BrowserOpener {
    /// Opens `url` in the user's default browser.
    ///
    /// - Returns: `true` on success (or on a best-effort platform where success
    ///   can't be confirmed synchronously). `false` if the platform has no
    ///   browser hook.
    @discardableResult
    @MainActor
    static func open(_ url: URL) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
        #else
        return false
        #endif
    }
}
