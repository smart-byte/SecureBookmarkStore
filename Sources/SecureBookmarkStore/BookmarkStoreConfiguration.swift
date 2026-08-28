import Foundation

/// Configuration for ``BookmarkStore``.
///
/// Customise the storage file name, stale-bookmark handling, and logging.
public struct BookmarkStoreConfiguration: Sendable {
    /// File name used inside the app's sandboxed `Application Support` directory.
    /// Customize only if you need multiple independent stores within one app.
    public var fileName: String

    /// When `true`, stale bookmarks are silently renewed while the security scope
    /// is still active. When `false`, stale bookmarks are reported but left as-is.
    public var autoRenewStaleBookmarks: Bool

    /// When `true`, ``BookmarkStore/loadAll()`` deletes bookmarks whose target is
    /// permanently gone, so dead entries don't accumulate and re-warn on every launch.
    ///
    /// Entries are only pruned when their containing volume is currently mounted —
    /// a bookmark on an unplugged external drive is kept, not discarded.
    public var pruneUnresolvableBookmarks: Bool

    /// Optional closure invoked for every notable event (info, warning, error).
    /// Integrate with `os.log`, `swift-log`, or any logging system you prefer.
    public var logHandler: (@Sendable (LogLevel, String) -> Void)?

    /// Severity levels emitted by the store.
    public enum LogLevel: String, Sendable {
        case info
        case warning
        case error
    }

    /// Sensible defaults: file named `"bookmarks.data"`, auto-renew enabled, no logging.
    public static let `default` = BookmarkStoreConfiguration(
        fileName: "bookmarks.data",
        autoRenewStaleBookmarks: true,
        pruneUnresolvableBookmarks: false,
        logHandler: nil
    )

    public init(
        fileName: String = "bookmarks.data",
        autoRenewStaleBookmarks: Bool = true,
        pruneUnresolvableBookmarks: Bool = false,
        logHandler: (@Sendable (LogLevel, String) -> Void)? = nil
    ) {
        self.fileName = fileName
        self.autoRenewStaleBookmarks = autoRenewStaleBookmarks
        self.pruneUnresolvableBookmarks = pruneUnresolvableBookmarks
        self.logHandler = logHandler
    }
}
