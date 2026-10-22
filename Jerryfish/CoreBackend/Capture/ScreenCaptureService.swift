import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// ============================================================
// 选区截屏数据流服务
//
// 坐标系约定（全项目唯一真相）：
//   - Cocoa / NSScreen：原点在主屏 **左下**，y 向上。
//   - CoreGraphics / ScreenCaptureKit：原点在主屏 **左上**，y 向下。
//   - 本服务的公开 API 一律接收 **CG 全局点坐标（原点左上）**，
//     与 `CGDisplayBounds` / `CGWindowListCreateImage` 一致，便于跨屏换算。
// ============================================================

nonisolated public enum ScreenGeometry {

    /// 主屏（含菜单栏的那块）高度，用于两套坐标系互转。
    public static var primaryDisplayHeight: CGFloat {
        // NSScreen.screens[0] 即主屏，其 frame.origin 为 (0,0)
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// NSScreen（左下原点）→ CG 全局点（左上原点）
    public static func toGlobalTopLeft(_ cocoaRect: CGRect) -> CGRect {
        let height = primaryDisplayHeight
        return CGRect(
            x: cocoaRect.minX,
            y: height - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
    }

    /// CG 全局点（左上原点）→ NSScreen（左下原点）
    public static func toCocoa(_ globalRect: CGRect) -> CGRect {
        let height = primaryDisplayHeight
        return CGRect(
            x: globalRect.minX,
            y: height - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    /// 某块显示器（以 CG 全局点边界标识）的 backing scale factor。
    ///
    /// 注意：`CGDisplayPixelsWide` 返回的是 **面板原生像素**，在 macOS「更多空间」
    /// 缩放模式下它与 backing store 的实际像素数并不一致（本机 2560×1440 面板
    /// 在 scale=2 时 backing store 为 5120×2880）。想要拿到与 `screencapture`
    /// 等价的清晰度，必须用「点 × backingScaleFactor」。
    public static func backingScaleFactor(forGlobalBounds bounds: CGRect) -> CGFloat {
        let cocoa = toCocoa(bounds)
        if let match = NSScreen.screens.first(where: {
            abs($0.frame.minX - cocoa.minX) < 1 && abs($0.frame.minY - cocoa.minY) < 1
        }) {
            return match.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 1
    }

    /// 所有活动显示器的 CG 全局边界（原点左上）。
    public static func activeDisplayBounds() -> [(displayID: CGDirectDisplayID, bounds: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
    }

    /// 选区中心所在的显示器（找不到时回退到主显示器）。
    public static func display(containing rect: CGRect) -> (displayID: CGDirectDisplayID, bounds: CGRect)? {
        let displays = activeDisplayBounds()
        let probe = CGPoint(x: rect.midX, y: rect.midY)

        if let hit = displays.first(where: { $0.bounds.contains(probe) }) { return hit }
        // 选区跨屏：取交集面积最大者
        return displays
            .map { ($0, $0.bounds.intersection(rect)) }
            .filter { !$1.isNull }
            .max { lhs, rhs in
                lhs.1.width * lhs.1.height < rhs.1.width * rhs.1.height
            }
            .map { ($0.0.displayID, $0.0.bounds) }
            ?? displays.first.map { ($0.displayID, $0.bounds) }
    }
}

nonisolated public enum ScreenCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case emptySelection
    case noDisplay
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "需要「屏幕录制」权限才能截屏翻译。请在系统设置 → 隐私与安全性 → 屏幕录制中勾选本应用。")
        case .emptySelection:
            return String(localized: "选区太小，请重新框选。")
        case .noDisplay:
            return String(localized: "找不到与选区匹配的显示器。")
        case .captureFailed(let reason):
            return String(localized: "截屏失败：\(reason)")
        }
    }
}

nonisolated public struct ScreenCaptureService: Sendable {

    /// 最小有效选区（点）
    public static let minimumSelectionSide: CGFloat = 8

    // MARK: - 权限

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统权限弹窗（仅首次有效；已拒绝需用户手动在系统设置中开启）。
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - 截屏

    /// 截取屏幕区域。
    ///
    /// - Parameters:
    ///   - rect: **CG 全局点坐标（原点左上）**，可跨屏。
    ///   - excludingWindowNumbers: 需要从画面中排除的窗口编号（例如本应用的截屏遮罩），
    ///     保证蒙层不会被拍进图里。
    /// - Returns: 该区域的位图（分辨率 = 点 × 显示器缩放）。
    @concurrent
    nonisolated public static func captureRegion(
        _ rect: CGRect,
        excludingWindowNumbers: Set<Int> = []
    ) async throws -> CGImage {
        let rect = rect.standardized
        guard rect.width >= minimumSelectionSide, rect.height >= minimumSelectionSide else {
            throw ScreenCaptureError.emptySelection
        }
        guard hasPermission() else { throw ScreenCaptureError.permissionDenied }

        // 主路径：内容过滤器 + 全屏配置 + 本地裁剪。
        // 这样可以 **精确排除** 自身遮罩窗口，且完全规避 sourceRect 的坐标系歧义。
        if let image = try? await captureViaContentFilter(rect, excluding: excludingWindowNumbers) {
            return image
        }
        // 兜底路径：macOS 15.2+ 的区域截图 API（依赖遮罩窗口 sharingType = .none 排除自身）
        do {
            return try await captureViaRegionAPI(rect)
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }

    // MARK: - 主路径

    @concurrent
    nonisolated private static func captureViaContentFilter(
        _ rect: CGRect,
        excluding windowNumbers: Set<Int>
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = ScreenGeometry.display(containing: rect) else {
            throw ScreenCaptureError.noDisplay
        }
        guard let display = content.displays.first(where: { $0.displayID == target.displayID })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw ScreenCaptureError.noDisplay
        }

        // CGDisplayBounds 为全局左上原点，与我们的 API 约定一致
        let displayBounds = target.bounds.width > 0 && target.bounds.height > 0
            ? target.bounds
            : CGDisplayBounds(display.displayID)

        let excluded = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        // 输出分辨率 = 点 × backingScaleFactor，与窗口服务器 backing store 一致。
        // （CGDisplayPixelsWide 在缩放模式下返回面板原生像素，会导致截图仅 1x，
        //   小字号文本的 OCR 精度明显下降。）
        let scale = ScreenGeometry.backingScaleFactor(forGlobalBounds: displayBounds)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((displayBounds.width * scale).rounded()))
        configuration.height = max(1, Int((displayBounds.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        configuration.queueDepth = 1
        configuration.captureResolution = .best

        let fullImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return try crop(fullImage, globalRect: rect, displayBounds: displayBounds)
    }

    /// 从整块屏幕位图中裁出选区（CGImage 裁剪空间为原点左上）。
    nonisolated static func crop(
        _ image: CGImage,
        globalRect: CGRect,
        displayBounds: CGRect
    ) throws -> CGImage {
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            throw ScreenCaptureError.noDisplay
        }
        let scaleX = CGFloat(image.width) / displayBounds.width
        let scaleY = CGFloat(image.height) / displayBounds.height

        let local = CGRect(
            x: globalRect.minX - displayBounds.minX,
            y: globalRect.minY - displayBounds.minY,
            width: globalRect.width,
            height: globalRect.height
        )

        let pixelRect = CGRect(
            x: (local.minX * scaleX).rounded(.down),
            y: (local.minY * scaleY).rounded(.down),
            width: (local.width * scaleX).rounded(.up),
            height: (local.height * scaleY).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect) else {
            throw ScreenCaptureError.captureFailed("裁剪区域超出屏幕范围")
        }
        return cropped
    }

    // MARK: - 兜底路径

    @concurrent
    nonisolated private static func captureViaRegionAPI(_ rect: CGRect) async throws -> CGImage {
        guard #available(macOS 15.2, *) else {
            throw ScreenCaptureError.captureFailed("当前系统版本不支持区域截屏")
        }
        return try await SCScreenshotManager.captureImage(in: rect)
    }

    // MARK: - 图片落盘（调试 / 导出）

    public static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
