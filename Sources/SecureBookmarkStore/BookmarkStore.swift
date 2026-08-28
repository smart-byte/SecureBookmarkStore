import Foundation

/// Thread-safe, `actor`-based manager for macOS security-scoped bookmarks.
///
/// `BookmarkStore` persists bookmark data to `~/Library/Application Support/<fileName>`
/// using `NSKeyedArchiver` with secure coding enabled. It tracks active security scopes
/// and provides resolved URLs for sandboxed file access.
///
/// ## Quick Start
/// ```swift
/// let store = BookmarkStore(
///     configuration: .init(fileName: "com.myapp.bookmarks.data")
/// )
///
/// // At app launch — restore all persisted bookmarks
/// try await store.loadAll()
///
/// // After NSOpenPanel / drag-and-drop — persist a new bookmark
/// try await store.save(url: selectedURL)
///
/// // When reading files — get the security-scoped URL
/// if let resolved = await store.resolvedURL(for: originalURL) {
///     let data = try Data(contentsOf: resolved)
/// }
/// ```
public actor BookmarkStore {
    // MARK: - Properties

    private var activeScopes: [URL: URL] = [:]
    private let configuration: BookmarkStoreConfiguration

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return appSupport.appendingPathComponent(configuration.fileName)
    }

    // MARK: - Init

    /// Creates a new bookmark store with the given configuration.
    ///
    /// - Parameter configuration: Storage and behavior options.
    ///   Defaults to ``BookmarkStoreConfiguration/default``.
    public init(configuration: BookmarkStoreConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public API — Save

    /// Creates and persists a security-scoped bookmark for the given URL.
    ///
    /// Call this after the user selects a file or folder through `NSOpenPanel`,
    /// drag-and-drop, or any other user-initiated gesture that grants temporary access.
    ///
    /// - Parameter url: The URL to bookmark. Must be accessible at the time of calling.
    /// - Throws: ``BookmarkStoreError/bookmarkCreationFailed(url:underlying:)`` or
    ///   ``BookmarkStoreError/scopeAccessDenied(url:)`` or
    ///   ``BookmarkStoreError/writeFailed(underlying:)``.
    public func save(url: URL) throws {
        let previousDictionary = try readDictionary()
        var dictionary = previousDictionary
        let bookmarkData = try createBookmarkData(for: url)
        dictionary[url] = bookmarkData
        try writeDictionary(dictionary)

        do {
            try restoreBookmark(originalURL: url, data: bookmarkData)
        } catch {
            try rollbackSave(to: previousDictionary, restoring: [url])
            throw error
        }

        log(.info, "Saved bookmark for \(url.lastPathComponent)")
    }

    /// Creates and persists security-scoped bookmarks for multiple URLs at once.
    ///
    /// More efficient than calling ``save(url:)`` in a loop because the dictionary
    /// is read and written only once.
    ///
    /// - Parameter urls: The URLs to bookmark.
    public func save(urls: [URL]) throws {
        let previousDictionary = try readDictionary()
        var dictionary = previousDictionary
        var bookmarks: [(URL, Data)] = []
        for url in urls {
            let data = try createBookmarkData(for: url)
            dictionary[url] = data
            bookmarks.append((url, data))
        }
        try writeDictionary(dictionary)

        do {
            for (url, data) in bookmarks {
                try restoreBookmark(originalURL: url, data: data)
            }
        } catch {
            try rollbackSave(to: previousDictionary, restoring: urls)
            throw error
        }

        log(.info, "Saved \(urls.count) bookmark(s)")
    }

    // MARK: - Public API — Load & Restore

    /// Loads and restores all persisted bookmarks from disk.
    ///
    /// Call this once at app launch. Each bookmark is resolved and its security scope
    /// is activated. Stale bookmarks are automatically renewed when
    /// ``BookmarkStoreConfiguration/autoRenewStaleBookmarks`` is enabled (the default).
    ///
    /// - Returns: A ``LoadResult`` describing how many bookmarks were restored vs. failed.
    @discardableResult
    public func loadAll() throws -> LoadResult {
        let dictionary = try readDictionary()
        log(.info, "Loaded \(dictionary.count) bookmark(s) from disk")

        var restored = 0
        var failedURLs: [URL] = []
        var prunableURLs: [URL] = []
        for (url, data) in dictionary {
            do {
                try restoreBookmark(originalURL: url, data: data)
                restored += 1
            } catch {
                log(.warning, "Skipping bookmark for \(url.lastPathComponent): \(error.localizedDescription)")
                failedURLs.append(url)
                if isPermanentlyGone(url) {
                    prunableURLs.append(url)
                }
            }
        }

        if configuration.pruneUnresolvableBookmarks, !prunableURLs.isEmpty {
            var remaining = dictionary
            for url in prunableURLs {
                remaining.removeValue(forKey: url)
            }
            do {
                try writeDictionary(remaining)
                log(.info, "Pruned \(prunableURLs.count) unresolvable bookmark(s)")
            } catch {
                log(.warning, "Failed to prune unresolvable bookmarks: \(error.localizedDescription)")
            }
        }

        log(.info, "Restored \(restored)/\(dictionary.count) bookmark(s)")
        return LoadResult(
            total: dictionary.count,
            restored: restored,
            failed: failedURLs.count,
            failedURLs: failedURLs,
            pruned: configuration.pruneUnresolvableBookmarks ? prunableURLs.count : 0
        )
    }

    /// Loads and restores a single persisted bookmark.
    ///
    /// Useful when you need to lazily restore access to a specific URL
    /// rather than loading everything at once.
    ///
    /// - Parameter url: The original URL used when the bookmark was saved.
    /// - Returns: `true` if the bookmark was found and successfully restored.
    @discardableResult
    public func load(for url: URL) throws -> Bool {
        let dictionary = try readDictionary()
        guard let data = dictionary[url] else { return false }
        try restoreBookmark(originalURL: url, data: data)
        return true
    }

    // MARK: - Public API — Query

    /// Returns the resolved security-scoped URL for a previously saved bookmark.
    ///
    /// Use this URL for actual file I/O in sandboxed apps. Returns `nil` if no
    /// active scope exists for the given URL.
    ///
    /// - Parameter originalURL: The URL as originally passed to ``save(url:)``.
    public func resolvedURL(for originalURL: URL) -> URL? {
        activeScopes[originalURL]
    }

    /// Whether the store has an active security scope for the given URL.
    ///
    /// - Parameter url: The original URL.
    public func hasActiveScope(for url: URL) -> Bool {
        activeScopes[url] != nil
    }

    /// Checks if the bookmarked resource is both scope-active and physically reachable on disk.
    ///
    /// - Parameter url: The original URL.
    public func isAccessible(_ url: URL) -> Bool {
        guard let resolved = activeScopes[url] else { return false }
        return (try? resolved.checkResourceIsReachable()) ?? false
    }

    /// Returns all URLs that currently have an active security scope.
    public var activeScopedURLs: [URL] {
        Array(activeScopes.keys)
    }

    // MARK: - Public API — Remove & Lifecycle

    /// Removes a single bookmark and stops its security-scoped access.
    ///
    /// - Parameter url: The original URL.
    public func remove(url: URL) throws {
        stopAccessing(url: url)
        var dictionary = try readDictionary()
        dictionary[url] = nil
        try writeDictionary(dictionary)
        log(.info, "Removed bookmark for \(url.lastPathComponent)")
    }

    /// Removes multiple bookmarks and stops their security-scoped access.
    ///
    /// - Parameter urls: The original URLs.
    public func remove(urls: [URL]) throws {
        for url in urls {
            stopAccessing(url: url)
        }
        var dictionary = try readDictionary()
        for url in urls {
            dictionary[url] = nil
        }
        try writeDictionary(dictionary)
        log(.info, "Removed \(urls.count) bookmark(s)")
    }

    /// Stops all active security scopes and deletes the bookmark file from disk.
    public func clearAll() throws {
        for (_, scopedURL) in activeScopes {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        activeScopes.removeAll()

        let url = storageURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        log(.info, "Cleared all bookmarks")
    }

    /// Stops the security-scoped access for a single URL without removing the persisted bookmark.
    ///
    /// The bookmark remains on disk and can be restored later via ``load(for:)`` or ``loadAll()``.
    public func stopAccessing(url: URL) {
        if let scopedURL = activeScopes.removeValue(forKey: url) {
            scopedURL.stopAccessingSecurityScopedResource()
        }
    }

    /// Stops all active security scopes without deleting persisted bookmarks.
    public func stopAll() {
        for (_, scopedURL) in activeScopes {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        activeScopes.removeAll()
    }

    // MARK: - Internal — Bookmark Operations

    private func restoreBookmark(originalURL: URL, data: Data) throws {
        var isStale = false

        let resolvedURL = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            log(.error, "Scope access denied: \(resolvedURL.lastPathComponent)")
            throw BookmarkStoreError.scopeAccessDenied(url: resolvedURL)
        }

        // Stop any previously active scope for this URL to prevent leaking
        // unbalanced startAccessingSecurityScopedResource() calls.
        if let previousScope = activeScopes[originalURL] {
            previousScope.stopAccessingSecurityScopedResource()
        }

        activeScopes[originalURL] = resolvedURL

        if isStale, configuration.autoRenewStaleBookmarks {
            log(.info, "Renewing stale bookmark: \(resolvedURL.lastPathComponent)")
            do {
                let fresh = try createBookmarkData(for: resolvedURL)
                var dictionary = try readDictionary()
                dictionary[originalURL] = fresh
                try writeDictionary(dictionary)
            } catch {
                log(.warning, "Failed to renew stale bookmark for \(resolvedURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

    }

    /// Whether a failed bookmark's target is gone for good, rather than merely
    /// unavailable right now.
    ///
    /// A bookmark on an unmounted volume (unplugged drive, disconnected share) must
    /// survive — so an entry only counts as permanently gone when the closest
    /// existing ancestor directory is reachable and the file itself is absent.
    #if DEBUG
        /// Test seam for the volume-safety heuristic.
        func isPermanentlyGoneForTesting(_ url: URL) -> Bool { isPermanentlyGone(url) }
    #endif

    private func isPermanentlyGone(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if FileManager.default.fileExists(atPath: url.path) { return false }

        // An unmounted volume looks exactly like a deleted folder, so check the
        // mount point explicitly: /Volumes/<name> missing means the drive is away.
        let components = URL(fileURLWithPath: url.path).pathComponents
        if components.count > 2, components[1] == "Volumes" {
            let mountPoint = "/\(components[1])/\(components[2])"
            if !FileManager.default.fileExists(atPath: mountPoint) { return false }
        }

        // Walk up until we hit a directory that exists. If we reach the root
        // without finding one, the volume itself is missing — keep the bookmark.
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            if FileManager.default.fileExists(atPath: parent.path) {
                return true
            }
            let next = parent.deletingLastPathComponent()
            if next == parent { break }
            parent = next
        }
        return false
    }

    private func createBookmarkData(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkStoreError.bookmarkCreationFailed(url: url, underlying: error)
        }
    }

    // MARK: - Internal — Persistence

    private func readDictionary() throws -> [URL: Data] {
        let url = storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let fileData = try Data(contentsOf: url)
        guard let result = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSURL.self, NSData.self],
            from: fileData
        ) as? [URL: Data] else {
            throw BookmarkStoreError.corruptedArchive
        }
        return result
    }

    private func writeDictionary(_ dictionary: [URL: Data]) throws {
        do {
            let url = storageURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: dictionary,
                requiringSecureCoding: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw BookmarkStoreError.writeFailed(underlying: error)
        }
    }

    private func rollbackSave(to dictionary: [URL: Data], restoring urls: [URL]) throws {
        for url in urls {
            stopAccessing(url: url)
        }

        do {
            try writeDictionary(dictionary)
        } catch {
            log(.error, "Failed to roll back bookmark persistence: \(error.localizedDescription)")
            throw error
        }

        for url in urls {
            guard let previousData = dictionary[url] else { continue }
            do {
                try restoreBookmark(originalURL: url, data: previousData)
            } catch {
                log(.warning, "Failed to restore previous scope for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Internal — Logging

    private func log(_ level: BookmarkStoreConfiguration.LogLevel, _ message: String) {
        configuration.logHandler?(level, message)
    }
}

// MARK: - Load Result

public extension BookmarkStore {
    /// Summary returned by ``loadAll()``.
    struct LoadResult: Sendable {
        /// Total number of bookmarks found on disk.
        public let total: Int
        /// Number of bookmarks successfully restored with active scopes.
        public let restored: Int
        /// Number of bookmarks that could not be restored.
        public let failed: Int
        /// The URLs that could not be restored, in no particular order.
        public let failedURLs: [URL]
        /// Number of dead bookmarks removed from disk during this load.
        /// Always `0` unless ``BookmarkStoreConfiguration/pruneUnresolvableBookmarks`` is enabled.
        public let pruned: Int
    }
}
