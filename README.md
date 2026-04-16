# SecureBookmarkStore

A thread-safe, `actor`-based Swift package for managing **macOS security-scoped bookmarks** in sandboxed apps.

Security-scoped bookmarks let your sandboxed macOS app persist access to user-selected files and folders across launches. `SecureBookmarkStore` wraps the verbose, error-prone `URL.bookmarkData` / `URL(resolvingBookmarkData:)` dance into a clean, modern API.

## Features

- **Thread-safe** — built as a Swift `actor`, no data races
- **Automatic stale-bookmark renewal** — detects and refreshes expired bookmarks while the scope is still active
- **Symmetric scope lifecycle** — `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource` always paired correctly
- **Resolved URL tracking** — query the actual security-scoped URL for file I/O
- **Secure coding** — uses `NSKeyedArchiver` with `requiringSecureCoding: true`
- **Atomic writes** — bookmark file is written atomically to prevent corruption
- **Configurable** — custom file names, optional logging, stale-renewal toggle
- **Zero dependencies** — only `Foundation`, no UI framework imports

## Requirements

- macOS 13.0+
- Swift 6.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/smart-byte/SecureBookmarkStore.git", from: "1.0.0"),
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repository URL.

## Quick Start

### 1. Create a store at app launch

```swift
import SecureBookmarkStore

let bookmarkStore = BookmarkStore(
    configuration: .init(fileName: "com.myapp.bookmarks.data")
)
```

> Use a unique `fileName` per app to avoid collisions if you ship multiple apps.

### 2. Restore bookmarks on launch

```swift
// In your AppDelegate or App.init:
let result = try await bookmarkStore.loadAll()
print("Restored \(result.restored)/\(result.total) bookmarks")
```

### 3. Save bookmarks after user selection

```swift
// After NSOpenPanel, drag-and-drop, or any user gesture:
let panel = NSOpenPanel()
panel.canChooseDirectories = true
if panel.runModal() == .OK, let url = panel.url {
    try await bookmarkStore.save(url: url)
}
```

### 4. Access files using resolved URLs

```swift
if let resolved = await bookmarkStore.resolvedURL(for: originalURL) {
    let data = try Data(contentsOf: resolved)
    // ... use data
}
```

### 5. Check accessibility

```swift
// Has an active security scope?
await bookmarkStore.hasActiveScope(for: url)

// Active scope AND file exists on disk?
await bookmarkStore.isAccessible(url)

// Reachable via scope OR plain filesystem? (softer check)
await bookmarkStore.isReachable(url)
```

### 6. Clean up

```swift
// Remove a single bookmark (stops scope + deletes from disk)
try await bookmarkStore.remove(url: someURL)

// Stop all scopes without deleting persisted data
await bookmarkStore.stopAll()

// Nuclear option: stop all scopes AND delete the bookmark file
try await bookmarkStore.clearAll()
```

## Configuration

```swift
let store = BookmarkStore(
    configuration: BookmarkStoreConfiguration(
        fileName: "com.myapp.bookmarks.data",   // unique per app
        autoRenewStaleBookmarks: true,           // default: true
        logHandler: { level, message in          // optional
            print("[\(level.rawValue)] \(message)")
        }
    )
)
```

### Integrating with `swift-log`

```swift
import Logging

let logger = Logger(label: "com.myapp.bookmarks")

let store = BookmarkStore(
    configuration: .init(
        logHandler: { level, message in
            switch level {
            case .info:    logger.info("\(message)")
            case .warning: logger.warning("\(message)")
            case .error:   logger.error("\(message)")
            }
        }
    )
)
```

### Integrating with `os.log`

```swift
import os

let osLog = Logger(subsystem: "com.myapp", category: "bookmarks")

let store = BookmarkStore(
    configuration: .init(
        logHandler: { level, message in
            switch level {
            case .info:    osLog.info("\(message)")
            case .warning: osLog.warning("\(message)")
            case .error:   osLog.error("\(message)")
            }
        }
    )
)
```

## Entitlements

Your app needs these sandbox entitlements to use security-scoped bookmarks:

```xml
<!-- Required: sandbox + user-selected file access -->
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>

<!-- Required for persisting bookmarks across launches -->
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

## Error Handling

```swift
do {
    try await store.save(url: url)
} catch let error as BookmarkStoreError {
    switch error {
    case .corruptedArchive:
        // Bookmark file is damaged — clearAll() and start fresh
    case .bookmarkCreationFailed(let url, let underlying):
        // Could not create bookmark — file may not be accessible
    case .scopeAccessDenied(let url):
        // macOS denied the security scope — re-authorize via NSOpenPanel
    case .writeFailed(let underlying):
        // Disk write failed — check permissions / disk space
    }
}
```

## Re-Authorization Pattern

When a bookmark becomes permanently stale (e.g. after a system migration), you need the user to re-select the file:

```swift
func reauthorize(originalURL: URL) async throws {
    let panel = NSOpenPanel()
    panel.directoryURL = originalURL.deletingLastPathComponent()
    panel.nameFieldStringValue = originalURL.lastPathComponent
    panel.canChooseFiles = true

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

    try await bookmarkStore.remove(url: originalURL)
    try await bookmarkStore.save(url: selectedURL)
}
```

## How It Works

1. **Save**: `URL.bookmarkData(options: .withSecurityScope)` creates an opaque `Data` blob
2. **Persist**: All bookmarks are stored as `[URL: Data]` via `NSKeyedArchiver` (secure coding, atomic write)
3. **Restore**: `URL(resolvingBookmarkData:)` resolves the blob back to a URL
4. **Scope**: `startAccessingSecurityScopedResource()` activates the sandbox token
5. **Track**: The resolved URL is stored in an in-memory `[URL: URL]` map for fast lookup
6. **Renew**: If a bookmark is stale but still resolvable, fresh bookmark data is written back automatically

## License

MIT — see [LICENSE](LICENSE) for details.
