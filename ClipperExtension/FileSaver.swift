import Foundation

/// Saves the clipped markdown note and images to the Obsidian vault folder
/// using security-scoped bookmarks for file access.
enum FileSaver {

    /// Sendable configuration extracted from ClipperSettings for use across actor boundaries.
    struct SaveConfig: Sendable {
        let targetFolder: String
        let includeFrontmatter: Bool
        let vaultBookmark: Data?

        @MainActor
        init(from settings: ClipperSettings) {
            self.targetFolder = settings.targetFolder
            self.includeFrontmatter = settings.includeFrontmatter
            self.vaultBookmark = settings.vaultBookmark
        }
    }

    enum SaveError: LocalizedError {
        case noVaultConfigured
        case bookmarkResolutionFailed
        case accessDenied
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVaultConfigured:
                return "No vault folder configured. Open Obsidian Clipper and select your vault folder."
            case .bookmarkResolutionFailed:
                return "Could not access the vault folder. Please re-select it in settings."
            case .accessDenied:
                return "Permission denied. Please re-select the vault folder in Obsidian Clipper settings."
            case .writeFailed(let detail):
                return "Failed to write files: \(detail)"
            }
        }
    }

    /// Save a ClipResult to the configured Obsidian vault.
    /// Returns the URL of the saved markdown file.
    @discardableResult
    static func save(_ result: ClipResult, config: SaveConfig) throws -> URL {
        // Resolve the vault folder from the bookmark
        guard config.vaultBookmark != nil else {
            throw SaveError.noVaultConfigured
        }

        // resolveVaultURL is nonisolated — safe to call from any context
        let settings = ClipperSettings.resolveVaultBookmark(config.vaultBookmark)
        guard let resolved = settings else {
            throw SaveError.bookmarkResolutionFailed
        }
        let vaultURL = resolved.url

        // Start security-scoped access — must wrap ALL file I/O below.
        guard vaultURL.startAccessingSecurityScopedResource() else {
            throw SaveError.accessDenied
        }
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default

        // Build the target folder path
        let targetFolder = config.targetFolder.isEmpty ? "" : config.targetFolder
        let targetDir: URL
        if targetFolder.isEmpty {
            targetDir = vaultURL
        } else {
            targetDir = vaultURL.appendingPathComponent(targetFolder, isDirectory: true)
        }

        // Create target folder if needed
        if !fm.fileExists(atPath: targetDir.path) {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        // Sanitize the title for use as a folder/filename
        let safeTitle = sanitizeFilename(result.title)

        // Create a per-article subfolder to keep each clip self-contained
        var articleDir = targetDir.appendingPathComponent(safeTitle, isDirectory: true)

        // If a subfolder with the same name already exists (re-clip), append timestamp
        if fm.fileExists(atPath: articleDir.path) {
            let timestamp = Int(Date().timeIntervalSince1970)
            articleDir = targetDir.appendingPathComponent("\(safeTitle)-\(timestamp)", isDirectory: true)
        }

        try fm.createDirectory(at: articleDir, withIntermediateDirectories: true)

        // Save images if any
        var imageReferences: [String: String] = [:] // sourceURL -> relative markdown path
        if !result.images.isEmpty {
            let imagesDir = articleDir.appendingPathComponent("images", isDirectory: true)
            if !fm.fileExists(atPath: imagesDir.path) {
                try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            }

            for image in result.images {
                let imageURL = imagesDir.appendingPathComponent(image.filename)
                do {
                    try image.data.write(to: imageURL)
                    imageReferences[image.sourceURL.absoluteString] = "images/\(image.filename)"
                } catch {
                    // Non-fatal: skip this image
                    continue
                }
            }
        }

        // Generate markdown with local image references
        let markdown = result.toMarkdown(
            includeFrontmatter: config.includeFrontmatter,
            imageReferences: imageReferences
        )

        // Write the markdown file inside the article subfolder
        let mdFilename = "\(safeTitle).md"
        let finalURL = articleDir.appendingPathComponent(mdFilename)

        guard let mdData = markdown.data(using: .utf8) else {
            throw SaveError.writeFailed("Could not encode markdown as UTF-8")
        }

        do {
            try mdData.write(to: finalURL)
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }

        return finalURL
    }

    /// Remove characters that are invalid in filenames.
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:*?\"<>|\\")
        var sanitized = name.components(separatedBy: invalid).joined(separator: "-")
        // Collapse multiple dashes
        sanitized = sanitized.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        // Trim dashes and whitespace
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Limit length
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }
        return sanitized.isEmpty ? "Untitled" : sanitized
    }
}
