import Foundation
import XCTest

final class ApplicationIdentityTests: XCTestCase {
    func testApplicationIdentityIsStaticallyAccessoryOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = root.appendingPathComponent("Resources/Info.plist")
        let plistData = try Data(contentsOf: infoPlistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)

        let sourceRoot = root.appendingPathComponent("Sources/MarkdownCardAgent")
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let compactSource = try sourceURLs
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .filter { !$0.isWhitespace }

        XCTAssertFalse(compactSource.contains("setActivationPolicy(.regular)"))
        XCTAssertEqual(
            compactSource.components(separatedBy: "setActivationPolicy(.accessory)").count - 1,
            2
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourceRoot
                    .appendingPathComponent("UserInterfacePresenceCoordinator.swift").path
            )
        )
    }
}
