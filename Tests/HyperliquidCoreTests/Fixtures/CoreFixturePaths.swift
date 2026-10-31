import Foundation

/// Locate the SDK fixtures from any nested test module or dependency checkout.
enum CoreFixturePaths {
    static func packageRoot(filePath: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: String(describing: filePath)).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent("Sources/HyperliquidCore").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: String(describing: filePath)])
    }
}
