#if canImport(AppKit)
import AppKit
#else
// iOS：AppKit 的等价类型在本模块的 AppKitCompatIOS.swift 中映射；
// 这里补上原来由 AppKit 顺带带入的 Foundation / CoreGraphics / UIKit。
import Foundation
internal import CoreGraphics
import UIKit
#endif
public import Combine

// ============================================================
// 应用内 PDF 阅读器 —— 批注数据模型
//
// 设计原则：
//  - 只读文件：所有批注只存在于内存，绝不写回 PDF。
//  - 关 Tab / 关软件即全部丢弃。
//  - 批注参与文档级撤销/重做（复用 WorkspaceState 的 UndoManager）。
//  - 坐标一律用「页内归一化坐标」（相对 cropBox，原点左上，0...1），
//    因此缩放、滚动、窗口大小变化都不影响批注数据。
// ============================================================

// MARK: - 工具

enum PDFReaderTool: String, CaseIterable, Identifiable {
    case cursor
    case rectangle
    case ellipse
    case pen
    case line
    case highlight
    case text
    case eraser

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cursor:    return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .pen:       return "pencil.tip"
        case .line:      return "line.diagonal"
        case .highlight: return "highlighter"
        case .text:      return "textbox"
        case .eraser:    return "eraser"
        }
    }

    var title: String {
        switch self {
        case .cursor:    return String(localized: "Select")
        case .rectangle: return String(localized: "Rectangle")
        case .ellipse:   return String(localized: "Ellipse")
        case .pen:       return String(localized: "Pen")
        case .line:      return String(localized: "Line")
        case .highlight: return String(localized: "Highlight")
        case .text:      return String(localized: "Text")
        case .eraser:    return String(localized: "Eraser")
        }
    }

    /// 是否需要颜色 / 粗细 / 字号等样式控件
    var usesColor: Bool {
        switch self {
        case .cursor, .eraser: return false
        default: return true
        }
    }

    var usesStrokeWidth: Bool {
        switch self {
        case .text, .cursor, .eraser: return false
        default: return true
        }
    }

    var usesFontSize: Bool { self == .text }
}

// MARK: - 单条批注

enum PDFAnnotationKind: String, Equatable {
    case rectangle
    case ellipse
    case pen
    case line
    case highlight
    case text
}

struct PDFAnnotationItem: Identifiable, Equatable {
    let id: UUID
    var kind: PDFAnnotationKind
    var pageIndex: Int
    /// 归一化坐标（相对 cropBox，原点左上）
    var start: CGPoint
    var end: CGPoint
    /// 画笔 / 高亮的轨迹点（归一化）
    var points: [CGPoint]
    var colorHex: String
    var lineWidth: CGFloat
    var text: String
    var fontSize: CGFloat
    /// 【新增·可选】填充底色。nil = 不填充（与原行为完全一致）；
    /// 译文批注会设为不透明底色，用来盖住原文、避免中英重叠。
    var fillColorHex: String?

    init(
        id: UUID = UUID(),
        kind: PDFAnnotationKind,
        pageIndex: Int,
        start: CGPoint,
        end: CGPoint,
        points: [CGPoint] = [],
        colorHex: String,
        lineWidth: CGFloat,
        text: String = "",
        fontSize: CGFloat = 18,
        fillColorHex: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.start = start
        self.end = end
        self.points = points
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
        self.fillColorHex = fillColorHex
    }

    var color: NSColor { NSColor.fromHex(colorHex) ?? .systemRed }

    /// 填充底色（未设置时为 nil）
    var fillColor: NSColor? { fillColorHex.flatMap { NSColor.fromHex($0) } }

    /// 归一化包围盒
    var normalizedBounds: CGRect {
        if kind == .pen || kind == .highlight, !points.isEmpty {
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let x = min(start.x, end.x), y = min(start.y, end.y)
        return CGRect(x: x, y: y, width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// 平移（归一化增量）
    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// 按归一化包围盒做缩放（from → to）
    mutating func remap(from: CGRect, to: CGRect) {
        guard from.width > 0.0001, from.height > 0.0001 else { return }
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: to.minX + (p.x - from.minX) / from.width * to.width,
                y: to.minY + (p.y - from.minY) / from.height * to.height
            )
        }
        start = map(start)
        end = map(end)
        points = points.map(map)
    }
}

// MARK: - NSColor ↔ hex

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        #if os(macOS)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
        #endif
    }
}

// MARK: - 商店（内存态 + 撤销集成）

final class PDFAnnotationStore: ObservableObject {
    @Published var items: [PDFAnnotationItem] = []
    @Published var selectedItemID: UUID?

    @Published var tool: PDFReaderTool = .cursor
    @Published var colorHex: String = "#E64B35"
    @Published var lineWidth: CGFloat = 3
    @Published var fontSize: CGFloat = 18

    private let workspace: WorkspaceState
    private let documentID: UUID

    init(workspace: WorkspaceState, documentID: UUID) {
        self.workspace = workspace
        self.documentID = documentID
    }

    var color: NSColor { NSColor.fromHex(colorHex) ?? .systemRed }

    var selectedItem: PDFAnnotationItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: 撤销感知的原子替换

    /// 用新数组替换全部批注，并登记一步可撤销动作。
    func apply(_ newItems: [PDFAnnotationItem], actionName: String) {
        let old = items
        guard old != newItems else { return }

        let um = workspace.undoManager(for: documentID)
        um.beginUndoGrouping()
        um.registerUndo(withTarget: self) { target in
            // 撤销/重做时反向再走一次本方法，自动补齐另一半
            target.apply(old, actionName: actionName)
        }
        if !um.isUndoing && !um.isRedoing {
            um.setActionName(actionName)
            workspace.registerHistoryAction(docID: documentID, actionName: actionName)
        }
        um.endUndoGrouping()

        items = newItems
        if let id = selectedItemID, !newItems.contains(where: { $0.id == id }) {
            selectedItemID = nil
        }
    }

    func add(_ item: PDFAnnotationItem, actionName: String) {
        var next = items
        next.append(item)
        apply(next, actionName: actionName)
    }

    func remove(id: UUID, actionName: String) {
        apply(items.filter { $0.id != id }, actionName: actionName)
    }

    func update(_ item: PDFAnnotationItem, actionName: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var next = items
        next[index] = item
        apply(next, actionName: actionName)
    }
}
