import CoreGraphics
import Foundation

public struct AppConfig: Codable, Equatable {
    public var favorites: [String]
    public var recent: [String]
    public var launchAtLogin: Bool

    public init(favorites: [String] = [], recent: [String] = [], launchAtLogin: Bool = false) {
        self.favorites = favorites
        self.recent = recent
        self.launchAtLogin = launchAtLogin
    }

    public mutating func recordRecent(_ path: String, limit: Int = 50) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > limit {
            recent.removeSubrange(limit...)
        }
    }

    public mutating func toggleFavorite(_ path: String) {
        if let index = favorites.firstIndex(of: path) {
            favorites.remove(at: index)
        } else {
            favorites.insert(path, at: 0)
        }
    }
}

public enum OverlayPlacement {
    public static func origin(dialogFrame: CGRect, panelSize: CGSize, visibleFrame: CGRect, gap: CGFloat = 8) -> CGPoint {
        let right = CGPoint(x: dialogFrame.maxX + gap, y: dialogFrame.maxY - panelSize.height)
        if right.x + panelSize.width <= visibleFrame.maxX {
            return right
        }

        let left = CGPoint(x: dialogFrame.minX - panelSize.width - gap, y: dialogFrame.maxY - panelSize.height)
        if left.x >= visibleFrame.minX {
            return left
        }

        return CGPoint(x: dialogFrame.maxX - panelSize.width - gap, y: dialogFrame.maxY - panelSize.height - gap)
    }
}

public enum DialogHeuristic {
    private static let titleNeedles = ["open", "save", "export", "upload", "choose", "打开", "存储", "保存", "另存为", "导出", "上传", "选取", "选择"]

    public static func titleMatches(_ title: String) -> Bool {
        let normalized = title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return titleNeedles.contains(normalized)
    }

    public static func shouldScanControlTitles(role: String, subrole: String, title: String) -> Bool {
        (role == "AXSheet" || subrole == "AXDialog") && !titleMatches(title)
    }

    public static func acceptsWindow(role: String, subrole: String, title: String, hasControlTitleMatch: Bool) -> Bool {
        let isSheetOrDialog = role == "AXSheet" || subrole == "AXDialog"
        let isWindow = role == "AXWindow"
        guard isSheetOrDialog || isWindow else { return false }

        return titleMatches(title) || (isSheetOrDialog && hasControlTitleMatch)
    }
}

public enum OverlayUpdatePolicy {
    public static func shouldRenderOverlay(hasDialog: Bool, isJumping: Bool) -> Bool {
        hasDialog && !isJumping
    }

    public static func shouldRenderAfterJump(hasDialog: Bool) -> Bool {
        hasDialog
    }
}

public final class PathStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL = PathStore.defaultFileURL()) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenPathTrace/config.json")
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? decoder.decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: [.atomic])
    }
}
