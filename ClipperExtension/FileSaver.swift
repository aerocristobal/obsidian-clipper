import Foundation

/// Saves the clipped markdown note and images to the Obsidian vault folder
/// using security-scoped bookmarks for file access.
enum FileSaver {

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
    static func save(_ result: ClipResult, settings: ClipperSettings) throws -> URL {
        // Resolve the vault folder from the bookmark
        guard let bookmark = settings.vaultBookmark else {
            throw SaveError.noVaultConfigured
        }

        var isStale = false
        guard let vaultURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            throw SaveError.bookmarkResolutionFailed
        }

        // Start security-scoped access
        guard vaultURL.startAccessingSecurityScopedResource() else {
            throw SaveError.accessDenied
        }
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default

        // Build the target folder path
        let targetFolder = settings.targetFolder.isEmpty ? "" : settings.targetFolder
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

        // Sanitize the title for use as a filename
        let safeTitle = sanitizeFilename(result.title)

        // Save images if any
        var imageReferences: [String: String] = [:] // sourceURL -> relative markdown path
        if !result.images.isEmpty {
            let imagesDir = targetDir.appendingPathComponent("images", isDirectory: true)
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

        // Generate markdown with local image references substituted
        var markdown = result.toMarkdown(
            includeFrontmatter: settings.includeFrontmatter
        )

        // Replace remote image URLs with local paths in the markdown
        for (remoteURL, localPath) in imageReferences {
            markdown = markdown.replacingOccurrences(
                of: remoteURL,
                with: localPath
            )
        }

        // Write the markdown file
        let mdFilename = "\(safeTitle).md"
        let mdURL = targetDir.appendingPathComponent(mdFilename)

        // If a file with this name already exists, append a timestamp
        let finalURL: URL
        if fm.fileExists(atPath: mdURL.path) {
            let timestamp = Int(Date().timeIntervalSince1970)
            let uniqueName = "\(safeTitle)-\(timestamp).md"
            finalURL = targetDir.appendingPathComponent(uniqueName)
        } else {
            finalURL = mdURL
        }

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
    private static func sanitizeFilename(_ name: String) -> String {
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
