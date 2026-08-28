import Foundation
@testable import SecureBookmarkStore
import Testing

/// Minimal thread-safe wrapper for test assertions.
final class LockIsolated<Value: Sendable>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        _value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&_value)
    }
}

// MARK: - Helpers

private func makeStore(
    fileName: String = "test-\(UUID().uuidString).data",
    autoRenew: Bool = true,
    prune: Bool = false,
    logHandler: (@Sendable (BookmarkStoreConfiguration.LogLevel, String) -> Void)? = nil
) -> BookmarkStore {
    BookmarkStore(configuration: .init(
        fileName: fileName,
        autoRenewStaleBookmarks: autoRenew,
        pruneUnresolvableBookmarks: prune,
        logHandler: logHandler
    ))
}

private func makeTempFile(content: String = "test") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecureBookmarkStoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(UUID().uuidString + ".txt")
    try content.write(to: file, atomically: true, encoding: .utf8)
    return file
}

private func storageURL(for fileName: String) -> URL {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return appSupport.appendingPathComponent(fileName)
}

// MARK: - Configuration

@Suite("BookmarkStoreConfiguration")
struct ConfigurationTests {
    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config = BookmarkStoreConfiguration.default
        #expect(config.fileName == "bookmarks.data")
        #expect(config.autoRenewStaleBookmarks == true)
        #expect(config.logHandler == nil)
    }

    @Test("Custom configuration preserves values")
    func customConfiguration() {
        let logMessages = LockIsolated<[String]>([])
        let config = BookmarkStoreConfiguration(
            fileName: "com.test.bookmarks.data",
            autoRenewStaleBookmarks: false,
            logHandler: { _, message in logMessages.withLock { $0.append(message) } }
        )

        #expect(config.fileName == "com.test.bookmarks.data")
        #expect(config.autoRenewStaleBookmarks == false)
        config.logHandler?(.info, "test")
        #expect(logMessages.withLock { $0 } == ["test"])
    }
}

// MARK: - Errors

@Suite("BookmarkStoreError")
struct ErrorTests {
    @Test("Error descriptions are human-readable")
    func errorDescriptions() {
        let corrupted = BookmarkStoreError.corruptedArchive
        #expect(corrupted.errorDescription?.contains("corrupted") == true)

        let writeFail = BookmarkStoreError.writeFailed(underlying: NSError(domain: "test", code: 1))
        #expect(writeFail.errorDescription?.contains("write") == true)

        let createFail = BookmarkStoreError.bookmarkCreationFailed(
            url: URL(fileURLWithPath: "/tmp/doc.pdf"),
            underlying: NSError(domain: "test", code: 2)
        )
        #expect(createFail.errorDescription?.contains("doc.pdf") == true)

        let scopeDenied = BookmarkStoreError.scopeAccessDenied(url: URL(fileURLWithPath: "/tmp/secret.pdf"))
        #expect(scopeDenied.errorDescription?.contains("secret.pdf") == true)
    }
}

// MARK: - Basic (empty store)

@Suite("BookmarkStore — Basic")
struct BookmarkStoreBasicTests {
    @Test("Init creates store without loading")
    func initDoesNotLoad() async {
        let store = makeStore()
        let urls = await store.activeScopedURLs
        #expect(urls.isEmpty)
    }

    @Test("loadAll on empty store returns zero results")
    func loadAllEmpty() async throws {
        let store = makeStore()
        let result = try await store.loadAll()
        #expect(result.total == 0)
        #expect(result.restored == 0)
        #expect(result.failed == 0)
    }

    @Test("resolvedURL returns nil for unknown URL")
    func resolvedURLUnknown() async {
        let store = makeStore()
        let result = await store.resolvedURL(for: URL(fileURLWithPath: "/tmp/nonexistent"))
        #expect(result == nil)
    }

    @Test("hasActiveScope returns false for unknown URL")
    func hasActiveScopeUnknown() async {
        let store = makeStore()
        let result = await store.hasActiveScope(for: URL(fileURLWithPath: "/tmp/nonexistent"))
        #expect(result == false)
    }

    @Test("clearAll on empty store does not throw")
    func clearAllEmpty() async throws {
        let store = makeStore()
        try await store.clearAll()
    }

    @Test("Log handler receives messages")
    func logHandlerCalled() async throws {
        let messages = LockIsolated<[(BookmarkStoreConfiguration.LogLevel, String)]>([])
        let store = makeStore(logHandler: { level, msg in
            messages.withLock { $0.append((level, msg)) }
        })
        _ = try await store.loadAll()
        #expect(messages.withLock { $0 }.contains(where: { $0.0 == .info }))
    }
}

// MARK: - Scope Lifecycle

@Suite("BookmarkStore — Scope Lifecycle")
struct BookmarkStoreScopeLifecycleTests {
    @Test("save activates scope immediately")
    func saveActivatesScope() async throws {
        let store = makeStore()
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        try await store.save(url: file)

        // Scope should be active without needing loadAll()
        #expect(await store.hasActiveScope(for: file) == true)
        #expect(await store.resolvedURL(for: file) != nil)

        try await store.clearAll()
    }

    @Test("Repeated save for same URL does not leak scopes")
    func repeatedSaveNoLeak() async throws {
        let store = makeStore()
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        // Save the same URL multiple times
        try await store.save(url: file)
        try await store.save(url: file)
        try await store.save(url: file)

        // Should still have exactly one active scope
        #expect(await store.activeScopedURLs.count == 1)
        #expect(await store.hasActiveScope(for: file) == true)

        try await store.clearAll()
    }

    @Test("Repeated loadAll does not leak scopes")
    func repeatedLoadAllNoLeak() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)

        // Load multiple times
        _ = try await store.loadAll()
        _ = try await store.loadAll()
        _ = try await store.loadAll()

        // Should still have exactly one active scope
        #expect(await store.activeScopedURLs.count == 1)

        try await store.clearAll()
    }

    @Test("load(for:) on already-active scope does not leak")
    func repeatedLoadForNoLeak() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)

        // Load the same URL again
        _ = try await store.load(for: file)
        _ = try await store.load(for: file)

        #expect(await store.activeScopedURLs.count == 1)

        try await store.clearAll()
    }
}

// MARK: - Persistence round-trips

@Suite("BookmarkStore — Persistence")
struct BookmarkStorePersistenceTests {
    @Test("save and loadAll round-trip")
    func saveAndLoadRoundTrip() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)

        // New store instance with same fileName reads from disk
        let store2 = makeStore(fileName: fileName)
        let result = try await store2.loadAll()

        #expect(result.total == 1)
        #expect(result.restored == 1)
        #expect(result.failed == 0)

        let resolved = await store2.resolvedURL(for: file)
        #expect(resolved != nil)

        // Cleanup
        try await store2.clearAll()
    }

    @Test("save(urls:) batch persists all")
    func saveBatch() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let files = try (0..<3).map { _ in try makeTempFile() }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = makeStore(fileName: fileName)
        try await store.save(urls: files)

        let store2 = makeStore(fileName: fileName)
        let result = try await store2.loadAll()

        #expect(result.total == 3)
        #expect(result.restored == 3)

        try await store2.clearAll()
    }

    @Test("load(for:) restores single bookmark lazily")
    func loadSingle() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file1 = try makeTempFile()
        let file2 = try makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let store = makeStore(fileName: fileName)
        try await store.save(urls: [file1, file2])

        let store2 = makeStore(fileName: fileName)
        let loaded = try await store2.load(for: file1)
        #expect(loaded == true)

        // Only file1 should have an active scope
        #expect(await store2.hasActiveScope(for: file1) == true)
        #expect(await store2.hasActiveScope(for: file2) == false)

        try await store2.clearAll()
    }

    @Test("load(for:) returns false for unknown URL")
    func loadSingleUnknown() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)

        let store2 = makeStore(fileName: fileName)
        let unknown = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).txt")
        let loaded = try await store2.load(for: unknown)
        #expect(loaded == false)

        try await store2.clearAll()
    }

    @Test("save overwrites existing bookmark for same URL")
    func saveOverwrite() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)
        try await store.save(url: file) // Save again — should not duplicate

        let store2 = makeStore(fileName: fileName)
        let result = try await store2.loadAll()
        #expect(result.total == 1)

        try await store2.clearAll()
    }

    @Test("Corrupted archive throws corruptedArchive error")
    func corruptedArchive() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let path = storageURL(for: fileName)

        // Write a valid archive containing the wrong type ([String: String] instead of [URL: Data])
        let wrongType: [String: String] = ["key": "value"]
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: wrongType,
            requiringSecureCoding: true
        )
        try archived.write(to: path, options: .atomic)
        defer { try? FileManager.default.removeItem(at: path) }

        let store = makeStore(fileName: fileName)
        do {
            _ = try await store.loadAll()
            Issue.record("Expected corruptedArchive error")
        } catch let error as BookmarkStoreError {
            guard case .corruptedArchive = error else {
                Issue.record("Expected corruptedArchive, got \(error)")
                return
            }
        }
    }

    @Test("Different fileNames are fully isolated")
    func fileNameIsolation() async throws {
        let fileName1 = "test-\(UUID().uuidString).data"
        let fileName2 = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store1 = makeStore(fileName: fileName1)
        try await store1.save(url: file)

        let store2 = makeStore(fileName: fileName2)
        let result = try await store2.loadAll()
        #expect(result.total == 0)

        try await store1.clearAll()
    }
}

// MARK: - Remove & Lifecycle

@Suite("BookmarkStore — Remove & Lifecycle")
struct BookmarkStoreLifecycleTests {
    @Test("remove(url:) removes bookmark from scope and disk")
    func removeSingle() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)
        _ = try await store.loadAll()
        #expect(await store.hasActiveScope(for: file) == true)

        try await store.remove(url: file)
        #expect(await store.hasActiveScope(for: file) == false)

        // Verify removed from disk too
        let store2 = makeStore(fileName: fileName)
        let result = try await store2.loadAll()
        #expect(result.total == 0)

        try? await store2.clearAll()
    }

    @Test("remove(urls:) batch removes all")
    func removeBatch() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let files = try (0..<3).map { _ in try makeTempFile() }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = makeStore(fileName: fileName)
        try await store.save(urls: files)
        _ = try await store.loadAll()

        try await store.remove(urls: Array(files.prefix(2)))

        #expect(await store.hasActiveScope(for: files[0]) == false)
        #expect(await store.hasActiveScope(for: files[1]) == false)
        #expect(await store.hasActiveScope(for: files[2]) == true)

        // Only one left on disk
        let store2 = makeStore(fileName: fileName)
        let result = try await store2.loadAll()
        #expect(result.total == 1)

        try await store2.clearAll()
    }

    @Test("stopAccessing removes scope but keeps persisted data")
    func stopAccessingKeepsPersisted() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)
        _ = try await store.loadAll()
        #expect(await store.hasActiveScope(for: file) == true)

        await store.stopAccessing(url: file)
        #expect(await store.hasActiveScope(for: file) == false)

        // Still on disk — loadAll should restore it
        _ = try await store.loadAll()
        #expect(await store.hasActiveScope(for: file) == true)

        try await store.clearAll()
    }

    @Test("stopAll removes all scopes but keeps persisted data")
    func stopAllKeepsPersisted() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let files = try (0..<2).map { _ in try makeTempFile() }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = makeStore(fileName: fileName)
        try await store.save(urls: files)
        _ = try await store.loadAll()
        #expect(await store.activeScopedURLs.count == 2)

        await store.stopAll()
        #expect(await store.activeScopedURLs.isEmpty)

        // Reload from disk
        let result = try await store.loadAll()
        #expect(result.restored == 2)

        try await store.clearAll()
    }

    @Test("clearAll deletes file from disk")
    func clearAllDeletesFile() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)

        let path = storageURL(for: fileName)
        #expect(FileManager.default.fileExists(atPath: path.path))

        try await store.clearAll()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(await store.activeScopedURLs.isEmpty)
    }
}

// MARK: - Query

@Suite("BookmarkStore — Query")
struct BookmarkStoreQueryTests {
    @Test("isAccessible returns true for active scope with existing file")
    func isAccessibleTrue() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)
        _ = try await store.loadAll()

        #expect(await store.isAccessible(file) == true)

        try await store.clearAll()
    }

    @Test("isAccessible returns false when file is deleted")
    func isAccessibleDeletedFile() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let file = try makeTempFile()

        let store = makeStore(fileName: fileName)
        try await store.save(url: file)
        _ = try await store.loadAll()

        try FileManager.default.removeItem(at: file)
        #expect(await store.isAccessible(file) == false)

        try await store.clearAll()
    }

    @Test("isAccessible returns false without active scope")
    func isAccessibleNoScope() async {
        let store = makeStore()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).txt")
        #expect(await store.isAccessible(file) == false)
    }

    @Test("activeScopedURLs tracks loaded bookmarks")
    func activeScopedURLsTracking() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let files = try (0..<3).map { _ in try makeTempFile() }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = makeStore(fileName: fileName)
        try await store.save(urls: files)
        _ = try await store.loadAll()

        let scoped = await store.activeScopedURLs
        #expect(scoped.count == 3)
        for file in files {
            #expect(scoped.contains(file))
        }

        try await store.clearAll()
    }
}

// MARK: - Logging

@Suite("BookmarkStore — Logging")
struct BookmarkStoreLoggingTests {
    @Test("save logs info message")
    func saveLogsInfo() async throws {
        let messages = LockIsolated<[(BookmarkStoreConfiguration.LogLevel, String)]>([])
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(logHandler: { level, msg in
            messages.withLock { $0.append((level, msg)) }
        })
        try await store.save(url: file)

        let logged = messages.withLock { $0 }
        #expect(logged.contains(where: { $0.0 == .info && $0.1.contains("Saved") }))

        try await store.clearAll()
    }

    @Test("remove logs info message")
    func removeLogsInfo() async throws {
        let messages = LockIsolated<[(BookmarkStoreConfiguration.LogLevel, String)]>([])
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(logHandler: { level, msg in
            messages.withLock { $0.append((level, msg)) }
        })
        try await store.save(url: file)
        _ = try await store.loadAll()
        try await store.remove(url: file)

        let logged = messages.withLock { $0 }
        #expect(logged.contains(where: { $0.0 == .info && $0.1.contains("Removed") }))
    }

    @Test("loadAll logs restored count")
    func loadAllLogsCount() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let messages = LockIsolated<[(BookmarkStoreConfiguration.LogLevel, String)]>([])
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = makeStore(fileName: fileName, logHandler: { level, msg in
            messages.withLock { $0.append((level, msg)) }
        })
        try await store.save(url: file)
        _ = try await store.loadAll()

        let logged = messages.withLock { $0 }
        #expect(logged.contains(where: { $0.0 == .info && $0.1.contains("Restored 1/1") }))

        try await store.clearAll()
    }

    @Test("All log levels are emitted across operations")
    func allLogLevelsUsed() async throws {
        let fileName = "test-\(UUID().uuidString).data"
        let messages = LockIsolated<[BookmarkStoreConfiguration.LogLevel]>([])

        let store = makeStore(fileName: fileName, logHandler: { level, _ in
            messages.withLock { $0.append(level) }
        })

        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        try await store.save(url: file)
        _ = try await store.loadAll()
        try await store.remove(url: file)

        let levels = messages.withLock { $0 }
        #expect(levels.contains(.info))
    }
}


// MARK: - Pruning unresolvable bookmarks

@Test("Deleted files are pruned when pruning is enabled")
func pruneRemovesDeadBookmarks() async throws {
    let fileName = "test-\(UUID().uuidString).data"
    let store = makeStore(fileName: fileName, prune: true)

    let keep = try makeTempFile()
    let doomed = try makeTempFile()
    try await store.save(urls: [keep, doomed])

    try FileManager.default.removeItem(at: doomed)

    let result = try await store.loadAll()
    #expect(result.total == 2)
    #expect(result.restored == 1)
    #expect(result.failedURLs == [doomed])
    #expect(result.pruned == 1)

    // The dead entry is gone from disk, the live one survived.
    let second = try await store.loadAll()
    #expect(second.total == 1)
    #expect(second.restored == 1)
    #expect(second.pruned == 0)
}

@Test("Pruning is off by default, so nothing is deleted behind the caller's back")
func pruningIsOptIn() async throws {
    let fileName = "test-\(UUID().uuidString).data"
    let store = makeStore(fileName: fileName)

    let doomed = try makeTempFile()
    try await store.save(url: doomed)
    try FileManager.default.removeItem(at: doomed)

    let result = try await store.loadAll()
    #expect(result.failed == 1)
    #expect(result.pruned == 0)
    // Entry is still on disk.
    #expect(try await store.loadAll().total == 1)
}

@Test("A bookmark on an unmounted volume is kept, not pruned")
func unmountedVolumeIsNotPruned() async throws {
    let store = makeStore(prune: true)
    let missingVolume = URL(fileURLWithPath: "/Volumes/NotMounted-\(UUID().uuidString)/photo.png")
    let deletedLocal = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gone-\(UUID().uuidString).png")

    // The unplugged drive must survive; the deleted local file must not.
    #expect(await store.isPermanentlyGoneForTesting(missingVolume) == false)
    #expect(await store.isPermanentlyGoneForTesting(deletedLocal) == true)
}
