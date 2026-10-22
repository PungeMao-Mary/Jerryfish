import AppKit
import CoreGraphics
import Foundation

// ============================================================
// 截屏时的「窗口点选」支持
//
// 交互：鼠标划过时高亮鼠标下方的窗口，点一下即把该窗口整块作为选区
// （与「拖动自由框选」并存）。
//
// 纯逻辑可与 UI 分离，因此这里做成可测试的静态方法。
// ============================================================

/// 一个可点选的窗口候选（坐标已换算到遮罩面板的局部坐标系，原点左上）。
nonisolated struct CaptureWindowCandidate: Identifiable, Equatable, Sendable {
    /// CGWindowID
    let id: Int
    /// 面板局部坐标（原点左上，单位：屏幕点）
    let bounds: CGRect
    /// 所属应用名（不需要屏幕录制权限即可获取）
    let ownerName: String

    /// 面积（防御性取绝对值：`CGRect.width` 在负宽度下的返回值并不直观）。
    var area: CGFloat { abs(bounds.size.width) * abs(bounds.size.height) }
}

nonisolated enum CaptureWindowSnapper {

    /// 从系统枚举当前屏幕上可点选的窗口（仅普通应用窗口，排除本应用自身）。
    ///
    /// - Parameter panelOrigin: 遮罩面板左上角在 CG 全局坐标（原点左上）中的位置。
    static func candidates(
        panelOrigin: CGPoint,
        excludingPIDs: Set<pid_t>,
        minimumSide: CGFloat = 80,
        minimumAlpha: Double = 0.05
    ) -> [CaptureWindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [CaptureWindowCandidate] = []
        result.reserveCapacity(list.count)

        for info in list {
            // 只要普通窗口层（layer 0）：排除菜单栏、Dock、状态项、HUD 等
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excludingPIDs.contains(pid) else { continue }
            guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > minimumAlpha else { continue }
            // 跳过没有窗口编号的辅助窗口
            guard let windowID = info[kCGWindowNumber as String] as? Int else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard rect.width >= minimumSide, rect.height >= minimumSide else { continue }

            let local = localize(rect, panelOrigin: panelOrigin)
            let owner = info[kCGWindowOwnerName as String] as? String ?? String(localized: "未知窗口")
            result.append(CaptureWindowCandidate(id: windowID, bounds: local, ownerName: owner))
        }
        return result
    }

    /// CG 全局屏幕坐标 → 遮罩面板局部坐标（纯平移）。
    ///
    /// 抽成纯函数便于确定性测试：实机枚举窗口时窗口可能被系统移动，
    /// 用它做对比会产生偶发失败。
    static func localize(_ globalBounds: CGRect, panelOrigin: CGPoint) -> CGRect {
        CGRect(
            x: globalBounds.minX - panelOrigin.x,
            y: globalBounds.minY - panelOrigin.y,
            width: globalBounds.width,
            height: globalBounds.height
        )
    }

    /// 从前到后命中测试。
    ///
    /// `CGWindowListCopyWindowInfo` 返回的顺序即为「前 → 后」，
    /// 因此第一个包含该点且面积不太小的窗口就是用户视觉上点到的那一个。
    static func hitTest(
        _ point: CGPoint,
        in candidates: [CaptureWindowCandidate],
        maximumAreaFraction: CGFloat = 0.95
    ) -> CaptureWindowCandidate? {
        candidates.first { candidate in
            guard candidate.bounds.contains(point) else { return false }
            // 避免「整屏无边框窗口」抢走点击（例如某些覆盖层/远程桌面）
            return candidate.area > 0
        }
    }

    /// 在候选列表中找出「包含该点、且面积最小」的窗口：
    /// 用于修正「大窗口盖住小窗口」时的直觉（点小窗口应该选小窗口）。
    static func hitTestPreferringSmallest(_ point: CGPoint, in candidates: [CaptureWindowCandidate]) -> CaptureWindowCandidate? {
        candidates
            .filter { $0.bounds.contains(point) }
            .min { $0.area < $1.area }
    }
}
