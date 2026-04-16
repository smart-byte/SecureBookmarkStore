import Foundation

/// Errors thrown by ``BookmarkStore``.
public enum BookmarkStoreError: LocalizedError, Sendable {
    /// The on-disk archive could not be decoded into `[URL: Data]`.
    case corruptedArchive

    /// `URL.bookmarkData(options:…)` failed for the given URL.
    case bookmarkCreationFailed(url: URL, underlying: any Error)

    /// `startAccessingSecurityScopedResource()` was denied for the resolved URL.
    case scopeAccessDenied(url: URL)

    /// The bookmark file could not be written to disk.
    case writeFailed(underlying: any Error)

    public var errorDescription: String? {
        switch self {
        case .corruptedArchive:
            "The bookmark archive is corrupted and could not be read."
        case let .bookmarkCreationFailed(url, error):
            "Failed to create bookmark for \(url.lastPathComponent): \(error.localizedDescription)"
        case let .scopeAccessDenied(url):
            "Security-scoped access was denied for \(url.lastPathComponent)."
        case let .writeFailed(error):
            "Failed to write bookmarks to disk: \(error.localizedDescription)"
        }
    }
}
