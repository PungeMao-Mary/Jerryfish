import AppKit
import Combine
import Observation
import SwiftUI

// ============================================================
// PDF 阅读器宿主环境（桥接层，不含任何自绘 / 交互逻辑）
//
// 项目内的 4 个 PDF 组件（PDFReaderView / PDFCanvasView /
// PDFReaderToolbar / PDFAnnotationModel）原本属于一个更大的宿主工程，
// 它们依赖宿主的「设计系统」与「工作区状态」。
//
// 本文件 **只** 补齐这些宿主侧依赖，不改动组件内部任何绘制与交互实现：
//   - 设计令牌：LocusSpacing / LocusColor / LocusShadow / Color.locus(_:)
//   - 工作区：LocusDocument / EditorPane / WorkspaceState（含撤销管理器）
//   - 首选项：UserSettingsManager
//   - 颜色面板：ColorPaletteManager / InlineColorPickerPopoverView
// ============================================================

// MARK: - 设计系统令牌

nonisolated public enum LocusSpacing {
    public static let gapXS: CGFloat = 4
    public static let gapS: CGFloat = 8
    public static let gapM: CGFloat = 12
    public static let gapL: CGFloat = 18
    public static let gapXL: CGFloat = 24
}

nonisolated public enum LocusRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 14
}

nonisolated public enum LocusColor {
    /// 工具栏「选中工具」底色：中性色，不随强调色变化。
    public static let toolSelected = Color.primary.opacity(0.10)
    public static let panelBackground = Color(nsColor: .windowBackgroundColor)
    public static let separator = Color.primary.opacity(0.12)
}

nonisolated public enum LocusShadow {
    public static let color = Color.black.opacity(0.18)
    public static let radius: CGFloat = 3
    public static let offsetY: CGFloat = 1
}

/// 语义色令牌。
nonisolated public enum LocusColorToken: Sendable {
    case textBackground
    case panelBackground
    case toolbarBackground
    case separator
    case accent
    case annotationText

    public var color: Color {
        switch self {
        case .textBackground: return Color(nsColor: .textBackgroundColor)
        case .panelBackground: return Color(nsColor: .windowBackgroundColor)
        case .toolbarBackground: return Color(nsColor: .controlBackgroundColor)
        case .separator: return Color.primary.opacity(0.12)
        case .accent: return Color.accentColor
        case .annotationText: return Color(red: 0.06, green: 0.36, blue: 0.55)
        }
    }
}

public extension Color {
    /// 语义色入口：`Color.locus(.textBackground)`
    nonisolated static func locus(_ token: LocusColorToken) -> Color { token.color }
}

// MARK: - 文档 / 工作区

/// PDF 阅读器渲染所需的文档句柄（只读，纯内存）。
public struct LocusDocument: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var fileURL: URL?

    public init(id: UUID = UUID(), title: String = "", fileURL: URL? = nil) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
    }
}

/// 编辑器面板类型（PDF 阅读器保留该参数以兼容原宿主接口）。
public enum EditorPane: Hashable, Sendable {
    case pdf
    case markdown
    case text
}

/// 工作区状态：为 `PDFAnnotationStore` 提供文档级撤销管理器与历史登记。
///
/// 使用 `@Observable`（而非 ObservableObject），以匹配 `PDFReaderView` 里的
/// `@Bindable var workspace: WorkspaceState`。
@Observable
public final class WorkspaceState {

    /// documentID → 文件 URL（PDFReaderView 通过它定位 PDF 文件）
    public var standaloneDocumentFileURLs: [UUID: URL] = [:]

    /// 最近一次登记的历史动作（供状态栏 / 调试展示）
    public private(set) var lastHistoryAction: (documentID: UUID, actionName: String)?

    /// 版本号：批注变化时自增，便于外部观察者刷新。
    public private(set) var annotationRevision: Int = 0

    private var undoManagers: [UUID: UndoManager] = [:]
    private var historyCounts: [UUID: Int] = [:]

    public init() {}

    // MARK: 撤销

    public func undoManager(for documentID: UUID) -> UndoManager {
        if let existing = undoManagers[documentID] { return existing }
        let manager = UndoManager()
        // 批注以「原子替换」方式整批提交，需自行分组，故关闭事件级自动分组
        manager.groupsByEvent = false
        manager.levelsOfUndo = 100
        undoManagers[documentID] = manager
        return manager
    }

    public func registerHistoryAction(docID documentID: UUID, actionName: String) {
        historyCounts[documentID, default: 0] += 1
        annotationRevision &+= 1
        lastHistoryAction = (documentID, actionName)
    }

    public func historyCount(for documentID: UUID) -> Int {
        historyCounts[documentID] ?? 0
    }

    public func canUndo(documentID: UUID) -> Bool {
        undoManager(for: documentID).canUndo
    }

    public func canRedo(documentID: UUID) -> Bool {
        undoManager(for: documentID).canRedo
    }

    public func undo(documentID: UUID) {
        let manager = undoManager(for: documentID)
        guard manager.canUndo else { return }
        manager.undo()
    }

    public func redo(documentID: UUID) {
        let manager = undoManager(for: documentID)
        guard manager.canRedo else { return }
        manager.redo()
    }

    public func removeDocument(id documentID: UUID) {
        _ = standaloneDocumentFileURLs.removeValue(forKey: documentID)
        undoManagers.removeValue(forKey: documentID)?.removeAllActions()
        historyCounts.removeValue(forKey: documentID)
        lastHistoryAction = nil
    }
}

// MARK: - 首选项

/// 应用首选项（保留 `pdfPerformanceSaverMode` 以兼容 PDFCanvasView 的性能节约模式）。
public final class UserSettingsManager: ObservableObject {

    public static let shared = UserSettingsManager()

    private enum Key {
        static let performanceSaver = "pdfPerformanceSaverMode"
        static let autoActivateOnCapture = "translationAutoActivateOnCapture"
        static let autoTranslate = "translationAutoTranslateEnabled"
        static let showMetrics = "translationShowPerformanceMetrics"
        static let pdfOverlayFontScale = "pdfOverlayFontScale"
        static let captureHintShown = "captureHintShown"
        static let sourceLanguage = "translationSourceLanguage"
        static let persistentRegion = "persistentTranslationRegion"
    }

    /// 性能节约模式：PDF 低分辨率渲染 + 缩放复用位图。
    @Published public var pdfPerformanceSaverMode: Bool {
        didSet { UserDefaults.standard.set(pdfPerformanceSaverMode, forKey: Key.performanceSaver) }
    }

    /// 停止输入后自动翻译（3 秒防抖）。
    @Published public var translationAutoTranslateEnabled: Bool {
        didSet { UserDefaults.standard.set(translationAutoTranslateEnabled, forKey: Key.autoTranslate) }
    }

    /// 是否在界面上显示性能耗时等调试信息（默认关闭）。
    @Published public var showsPerformanceMetrics: Bool {
        didSet { UserDefaults.standard.set(showsPerformanceMetrics, forKey: Key.showMetrics) }
    }

    /// 截屏翻译完成后是否自动把应用唤到前台。
    @Published public var autoActivateOnCapture: Bool {
        didSet { UserDefaults.standard.set(autoActivateOnCapture, forKey: Key.autoActivateOnCapture) }
    }

    /// PDF 译文批注字号缩放系数。
    @Published public var pdfOverlayFontScale: Double {
        didSet { UserDefaults.standard.set(pdfOverlayFontScale, forKey: Key.pdfOverlayFontScale) }
    }

    /// 是否已经展示过「拖动框选」提示（只在首次使用时显示一次）。
    @Published public var hasShownCaptureHint: Bool {
        didSet { UserDefaults.standard.set(hasShownCaptureHint, forKey: Key.captureHintShown) }
    }

    /// 全应用共用的原文语言。
    @Published public var sourceLanguage: TranslationSourceLanguage {
        didSet { UserDefaults.standard.set(sourceLanguage.rawValue, forKey: Key.sourceLanguage) }
    }

    /// 最近一次常驻翻译选区（CG 全局点坐标）。
    @Published public var persistentTranslationRegion: CGRect? {
        didSet {
            guard let rect = persistentTranslationRegion else {
                UserDefaults.standard.removeObject(forKey: Key.persistentRegion)
                return
            }
            UserDefaults.standard.set([Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height)], forKey: Key.persistentRegion)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        hasShownCaptureHint = defaults.bool(forKey: Key.captureHintShown)
        sourceLanguage = TranslationSourceLanguage(rawValue: defaults.string(forKey: Key.sourceLanguage) ?? "en") ?? .english
        if let values = defaults.array(forKey: Key.persistentRegion) as? [Double], values.count == 4 {
            persistentTranslationRegion = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        } else {
            persistentTranslationRegion = nil
        }
        pdfPerformanceSaverMode = defaults.bool(forKey: Key.performanceSaver)
        autoActivateOnCapture = defaults.object(forKey: Key.autoActivateOnCapture) as? Bool ?? true
        translationAutoTranslateEnabled = defaults.object(forKey: Key.autoTranslate) as? Bool ?? true
        showsPerformanceMetrics = defaults.bool(forKey: Key.showMetrics)
        pdfOverlayFontScale = defaults.object(forKey: Key.pdfOverlayFontScale) as? Double ?? 0.62
    }
}

// MARK: - 颜色面板

/// 最近使用颜色（PDF 批注工具栏的取色弹窗使用）。
public final class ColorPaletteManager: ObservableObject {

    public static let shared = ColorPaletteManager()

    /// 学术出版常用配色（Nature / NPG / Okabe-Ito 混合）。
    public static let presets: [String] = [
        "#E64B35", "#4DBBD5", "#00A087", "#3C5488", "#F39B7F", "#8491B4",
        "#91D1C2", "#DC0000", "#7E6148", "#B09C85", "#0072B2", "#D55E00",
        "#009E73", "#CC79A7", "#000000", "#555555",
    ]

    @Published public private(set) var recentHexes: [String]

    private static let storageKey = "recentAnnotationColors"
    private let maximumRecents = 12

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        recentHexes = stored.isEmpty ? Array(Self.presets.prefix(6)) : stored
    }

    public func addRecent(hex: String) {
        let normalized = hex.uppercased()
        guard normalized.count == 7, normalized.hasPrefix("#") else { return }
        var next = recentHexes.filter { $0 != normalized }
        next.insert(normalized, at: 0)
        recentHexes = Array(next.prefix(maximumRecents))
        UserDefaults.standard.set(recentHexes, forKey: Self.storageKey)
    }
}

/// 紧凑的内联取色弹窗：系统取色器 + 学术预设 + Hex 输入 + 最近使用。
public struct InlineColorPickerPopoverView: View {

    private let initialHex: String
    private let onChange: (String) -> Void

    @State private var hex: String
    @State private var color: Color

    public init(initialHex: String, onChange: @escaping (String) -> Void) {
        self.initialHex = initialHex
        self.onChange = onChange
        _hex = State(initialValue: initialHex.uppercased())
        _color = State(initialValue: Color(nsColor: NSColor.fromHex(initialHex) ?? .systemRed))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LocusSpacing.gapM) {
            HStack(spacing: LocusSpacing.gapS) {
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { newValue in
                        color = newValue
                        let value = newValue.locusHexString
                        if value != hex {
                            hex = value
                            onChange(value)
                        }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)

                TextField("#RRGGBB", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 96)
                    .onSubmit { applyHex() }
            }

            sectionTitle(String(localized: "预设"))
            presetGrid(ColorPaletteManager.presets)

            if !ColorPaletteManager.shared.recentHexes.isEmpty {
                sectionTitle(String(localized: "最近使用"))
                presetGrid(ColorPaletteManager.shared.recentHexes)
            }
        }
        .padding(12)
        .frame(width: 236)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func presetGrid(_ hexes: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 8), spacing: 6) {
            ForEach(hexes, id: \.self) { value in
                Button {
                    hex = value
                    color = Color(nsColor: NSColor.fromHex(value) ?? .systemRed)
                    onChange(value)
                } label: {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: NSColor.fromHex(value) ?? .systemRed))
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.primary.opacity(hex == value ? 0.55 : 0.18),
                                        lineWidth: hex == value ? 1.6 : 0.6)
                        )
                }
                .buttonStyle(.borderless)
                .help(value)
            }
        }
    }

    private func applyHex() {
        let normalized = hex.hasPrefix("#") ? hex : "#" + hex
        guard let nsColor = NSColor.fromHex(normalized) else { return }
        color = Color(nsColor: nsColor)
        hex = normalized.uppercased()
        onChange(hex)
    }
}

// MARK: - Color ↔ Hex

public extension Color {
    /// 转 `#RRGGBB`（sRGB）。
    /// `NSColor.hexString` 由宿主工程提供（默认 MainActor），因此本访问器同样运行在主线程。
    var locusHexString: String {
        NSColor(self).hexString
    }
}
