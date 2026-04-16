import Foundation

/// Shared settings accessible by both the main app and the share extension.
/// Uses an App Group (suite name) so both targets read/write the same UserDefaults.
///
/// Isolated to `@MainActor` for strict Sendable compliance — all property
/// access happens on the main thread, matching SwiftUI's expectation.
@MainActor
final class ClipperSettings: ObservableObject {

    nonisolated static let suiteName = "group.com.obsidian.clipper"

    private let defaults: UserDefaults

    /// The name of the Obsidian vault (e.g. "omniscient").
    @Published var vaultName: String {
        didSet { defaults.set(vaultName, forKey: Keys.vaultName) }
    }

    /// The folder inside the vault where clipped notes are saved (e.g. "Inbox").
    @Published var targetFolder: String {
        didSet { defaults.set(targetFolder, forKey: Keys.targetFolder) }
    }

    /// Security-scoped bookmark data for the chosen vault folder.
    /// Persisted so the share extension can re-resolve the URL without a new picker.
    @Published var vaultBookmark: Data? {
        didSet { defaults.set(vaultBookmark, forKey: Keys.vaultBookmark) }
    }

    /// Whether to run OCR on images and include the recognized text in the note.
    @Published var enableOCR: Bool {
        didSet { defaults.set(enableOCR, forKey: Keys.enableOCR) }
    }

    /// Whether to download and save images locally into an images/ subfolder.
    @Published var saveImages: Bool {
        didSet { defaults.set(saveImages, forKey: Keys.saveImages) }
    }

    /// Whether to include YAML frontmatter in the generated markdown.
    @Published var includeFrontmatter: Bool {
        didSet { defaults.set(includeFrontmatter, forKey: Keys.includeFrontmatter) }
    }

    init() {
        let defaults = UserDefaults(suiteName: ClipperSettings.suiteName) ?? .standard
        self.defaults = defaults
        self.vaultName = defaults.string(forKey: Keys.vaultName) ?? ""
        self.targetFolder = defaults.string(forKey: Keys.targetFolder) ?? "Inbox"
        self.vaultBookmark = defaults.data(forKey: Keys.vaultBookmark)
        self.enableOCR = defaults.object(forKey: Keys.enableOCR) as? Bool ?? true
        self.saveImages = defaults.object(forKey: Keys.saveImages) as? Bool ?? true
        self.includeFrontmatter = defaults.object(forKey: Keys.includeFrontmatter) as? Bool ?? true
    }

    struct ResolvedVault: Sendable {
        let url: URL
        let isStale: Bool
    }

    /// Resolve the vault folder URL from the persisted bookmark.
    /// The returned URL is NOT yet under security scope — callers must wrap
    /// their own `startAccessingSecurityScopedResource` / stop pair around
    /// any file I/O. If `isStale` is true, the caller should refresh the
    /// bookmark via `refreshBookmark(for:)` *while holding* scoped access.
    nonisolated func resolveVaultURL() -> ResolvedVault? {
        let defaults = UserDefaults(suiteName: ClipperSettings.suiteName) ?? .standard
        guard let bookmark = defaults.data(forKey: Keys.vaultBookmark) else { return nil }
        return Self.resolveVaultBookmark(bookmark)
    }

    /// Resolve a vault bookmark from raw bookmark data. This is nonisolated and Sendable-safe.
    nonisolated static func resolveVaultBookmark(_ bookmark: Data?) -> ResolvedVault? {
        guard let bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return ResolvedVault(url: url, isStale: isStale)
    }

    /// Re-persist a bookmark for a URL the caller already holds scoped access to.
    func refreshBookmark(for url: URL) {
        if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            vaultBookmark = fresh
        }
    }

    /// Persist a folder URL as a security-scoped bookmark.
    func saveVaultBookmark(for url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            vaultBookmark = data
        }
    }

    private enum Keys {
        static let vaultName = "vault_name"
        static let targetFolder = "target_folder"
        static let vaultBookmark = "vault_bookmark"
        static let enableOCR = "enable_ocr"
        static let saveImages = "save_images"
        static let includeFrontmatter = "include_frontmatter"
    }
}
