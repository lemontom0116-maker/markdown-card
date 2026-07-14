import Foundation

enum RendererLocator {
    static func indexURL(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        var directories: [URL] = []

        if let resourceURL = bundle.resourceURL {
            directories.append(resourceURL.appendingPathComponent("Renderer", isDirectory: true))
        }

        if let override = environment["MARKDOWN_CARD_RENDERER_DIR"], !override.isEmpty {
            directories.append(
                URL(fileURLWithPath: override, relativeTo: currentDirectory)
                    .standardizedFileURL
            )
        }

        directories.append(
            currentDirectory
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Renderer", isDirectory: true)
        )

        for directory in directories {
            let candidate = directory.appendingPathComponent("index.html", isDirectory: false)
            if FileManager.default.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
