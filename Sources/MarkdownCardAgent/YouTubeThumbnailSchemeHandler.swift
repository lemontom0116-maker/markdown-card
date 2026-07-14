import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import WebKit

final class YouTubeThumbnailSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "mdcard-asset"
    static let host = "youtube"
    static let attachmentHost = "attachment"

    private let loader: YouTubeThumbnailLoader
    private let attachmentStore: LocalAttachmentStore
    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var stoppedTasks: Set<ObjectIdentifier> = []

    init(
        loader: YouTubeThumbnailLoader = YouTubeThumbnailLoader(),
        attachmentStore: LocalAttachmentStore = LocalAttachmentStore()
    ) {
        self.loader = loader
        self.attachmentStore = attachmentStore
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        if let attachmentID = Self.attachmentID(from: urlSchemeTask.request.url),
           let data = attachmentStore.data(forAttachmentID: attachmentID)
        {
            let response = URLResponse(
                url: urlSchemeTask.request.url!,
                mimeType: "image/png",
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        guard let videoID = Self.videoID(from: urlSchemeTask.request.url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let taskBox = SchemeTaskBox(urlSchemeTask)
        let fallbackURL = URL(string: "\(Self.scheme)://\(Self.host)/\(videoID)")!
        let task = loader.load(videoID: videoID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, claim(identifier: identifier) else { return }
                switch result {
                case let .success(data):
                    let response = URLResponse(
                        url: taskBox.task.request.url ?? fallbackURL,
                        mimeType: "image/jpeg",
                        expectedContentLength: data.count,
                        textEncodingName: nil
                    )
                    taskBox.task.didReceive(response)
                    taskBox.task.didReceive(data)
                    taskBox.task.didFinish()
                case let .failure(error):
                    taskBox.task.didFailWithError(error)
                }
            }
        }

        lock.withLock {
            stoppedTasks.remove(identifier)
            if let task {
                activeTasks[identifier] = task
            }
        }
        task?.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let task = lock.withLock { () -> URLSessionDataTask? in
            stoppedTasks.insert(identifier)
            return activeTasks.removeValue(forKey: identifier)
        }
        task?.cancel()
    }

    static func videoID(from url: URL?) -> String? {
        guard let url,
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host
        else { return nil }
        let videoID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return videoID
    }

    static func attachmentID(from url: URL?) -> String? {
        guard let url,
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == attachmentHost
        else { return nil }
        let filename = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard filename.hasSuffix(".png") else { return nil }
        let identifier = String(filename.dropLast(4))
        return LocalAttachmentStore.isValidAttachmentID(identifier) ? identifier : nil
    }

    private func claim(identifier: ObjectIdentifier) -> Bool {
        lock.withLock {
            activeTasks.removeValue(forKey: identifier)
            if stoppedTasks.remove(identifier) != nil {
                return false
            }
            return true
        }
    }
}

final class YouTubeThumbnailLoader: @unchecked Sendable {
    static let maximumDownloadSize = 2 * 1_024 * 1_024
    static let maximumPixelDimension = 4_096
    static let allowedMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let session: URLSession
    private let cacheQueue = DispatchQueue(label: "com.garden100.MarkdownCard.youtube-thumbnail-cache")

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        session: URLSession? = nil
    ) {
        self.fileManager = fileManager
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.cacheDirectory = cacheDirectory
            ?? caches
                .appendingPathComponent("com.garden100.MarkdownCard", isDirectory: true)
                .appendingPathComponent("YouTube", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(
                configuration: configuration,
                delegate: YouTubeThumbnailRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    @discardableResult
    func load(
        videoID: String,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) -> URLSessionDataTask? {
        guard videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
              let remoteURL = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        else {
            completion(.failure(URLError(.badURL)))
            return nil
        }

        let cacheURL = cacheDirectory.appendingPathComponent("\(videoID).jpg", isDirectory: false)
        if let cached = try? Data(contentsOf: cacheURL),
           let validated = Self.validatedJPEG(from: cached)
        {
            completion(.success(validated))
            return nil
        } else if fileManager.fileExists(atPath: cacheURL.path) {
            try? fileManager.removeItem(at: cacheURL)
        }

        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/jpeg,image/png,image/webp", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.url?.scheme?.lowercased() == "https",
                  response.url?.host?.lowercased() == "i.ytimg.com",
                  let mimeType = response.mimeType?.lowercased(),
                  Self.allowedMIMETypes.contains(mimeType),
                  let data,
                  data.count <= Self.maximumDownloadSize,
                  let jpeg = Self.validatedJPEG(from: data)
            else {
                completion(.failure(URLError(.cannotDecodeContentData)))
                return
            }

            cacheQueue.async { [self] in
                try? self.fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
                try? jpeg.write(to: cacheURL, options: .atomic)
            }
            completion(.success(jpeg))
        }
        return task
    }

    static func validatedJPEG(from data: Data) -> Data? {
        guard data.count <= maximumDownloadSize,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= maximumPixelDimension,
              height.intValue <= maximumPixelDimension,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length <= maximumDownloadSize else {
            return nil
        }
        return output as Data
    }
}

private final class YouTubeThumbnailRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == "i.ytimg.com"
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private final class SchemeTaskBox: @unchecked Sendable {
    let task: WKURLSchemeTask

    init(_ task: WKURLSchemeTask) {
        self.task = task
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
