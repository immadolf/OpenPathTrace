import CoreGraphics
import Foundation
import OpenPathTraceCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("检查失败：\(message)\n", stderr)
        exit(1)
    }
}

var config = AppConfig(
    favorites: [],
    recent: (0..<55).map { "/tmp/path-\($0)" },
    launchAtLogin: false
)

config.recordRecent("/tmp/path-10")

check(config.recent.first == "/tmp/path-10", "已存在最近路径应移动到首位")
check(config.recent.count == 50, "最近路径最多保留 50 条")
check(Set(config.recent).count == config.recent.count, "最近路径应去重")
check(!config.recent.dropFirst().contains("/tmp/path-10"), "移动到首位后不应保留旧位置")

let visible = CGRect(x: 0, y: 0, width: 1_000, height: 800)
let panel = CGSize(width: 200, height: 180)

check(
    OverlayPlacement.origin(
        dialogFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
        panelSize: panel,
        visibleFrame: visible
    ) == CGPoint(x: 708, y: 320),
    "右侧有空间时应贴右侧"
)

check(
    OverlayPlacement.origin(
        dialogFrame: CGRect(x: 300, y: 100, width: 650, height: 400),
        panelSize: panel,
        visibleFrame: visible
    ) == CGPoint(x: 92, y: 320),
    "右侧不足且左侧有空间时应贴左侧"
)

check(
    OverlayPlacement.origin(
        dialogFrame: CGRect(x: 20, y: 100, width: 950, height: 400),
        panelSize: panel,
        visibleFrame: visible
    ) == CGPoint(x: 762, y: 312),
    "左右都不足时应覆盖在弹窗右上角"
)

check(
    !DialogHeuristic.acceptsWindow(
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: "Downloads",
        hasControlTitleMatch: true
    ),
    "普通 Finder 窗口即使包含 Open 控件也不应被识别为文件弹窗"
)

check(
    DialogHeuristic.acceptsWindow(
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: "Open",
        hasControlTitleMatch: false
    ),
    "标题为 Open 的标准窗口应被识别为文件弹窗"
)

check(
    DialogHeuristic.acceptsWindow(
        role: "AXSheet",
        subrole: "",
        title: "",
        hasControlTitleMatch: true
    ),
    "Sheet 可用控件文案作为文件弹窗兜底识别"
)

print("OpenPathTraceCoreChecks passed")
