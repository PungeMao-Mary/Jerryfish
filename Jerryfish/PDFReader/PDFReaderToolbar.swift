import SwiftUI

// ============================================================
// PDF 阅读器顶部工具栏：Liquid Glass 胶囊（与 Markdown 工具栏同款）。
// 当前选中的工具带阴影高亮。
// ============================================================

struct PDFReaderToolbar: View {
    @ObservedObject var store: PDFAnnotationStore
    /// 【新增·可选】胶囊最右侧的附加按钮组（本应用用来注入译文相关操作，
    /// 使「所有按钮统一在一个工具条里」）。nil = 与原先完全一致。
    var trailingAccessory: AnyView?

    @State private var showColorPopover = false
    @State private var showWidthPopover = false
    @State private var showFontPopover = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            capsule
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LocusSpacing.gapM)
        .padding(.vertical, LocusSpacing.gapS)
    }

    private var capsule: some View {
        HStack(spacing: 2) {
            // 左侧：批注工具
            ForEach(PDFReaderTool.allCases) { tool in
                toolButton(tool)
            }

            if store.tool.usesColor || store.tool.usesStrokeWidth || store.tool.usesFontSize {
                separator
            }

            if store.tool.usesColor {
                colorControl
            }
            if store.tool.usesStrokeWidth {
                widthControl
            }
            if store.tool.usesFontSize {
                fontControl
            }

            // 右侧：本应用注入的译文操作按钮组
            if let trailingAccessory {
                separator
                trailingAccessory
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .modifier(PDFGlassCapsule())
    }

    private var separator: some View {
        Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    // MARK: 工具按钮

    @ViewBuilder
    private func toolButton(_ tool: PDFReaderTool) -> some View {
        let isActive = store.tool == tool
        Button {
            store.tool = tool
            if tool != .cursor { store.selectedItemID = nil }
        } label: {
            Group {
                if tool == .text {
                    // Photoshop 风格：衬线体大写 T 作为“插入文字”工具图标
                    Text("T")
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                } else {
                    Image(systemName: tool.icon)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 26, height: 22)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.primary)
        .background(
            Capsule(style: .continuous)
                .fill(isActive ? LocusColor.toolSelected : Color.clear)
        )
        // 选中态阴影：设计系统默认中性色，不随强调色/用户选择的颜色变化
        .shadow(color: isActive ? LocusShadow.color : .clear,
                radius: isActive ? LocusShadow.radius : 0, x: 0, y: isActive ? LocusShadow.offsetY : 0)
        .help(tool.title)
        .accessibilityLabel(tool.title)
    }

    // MARK: 颜色

    private var colorControl: some View {
        Button {
            showColorPopover.toggle()
        } label: {
            Circle()
                .fill(Color(nsColor: store.color))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 26, height: 22)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Color"))
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
            InlineColorPickerPopoverView(initialHex: store.colorHex) { hex in
                // 拖动色轮/滑块时只实时改颜色，不写“最近颜色”
                store.colorHex = hex
            }
        }
        .onChange(of: showColorPopover) { _, isShowing in
            // 弹窗关闭时才把最终颜色登记一次到“最近颜色”（而不是每帧拖拽都写）
            if !isShowing {
                ColorPaletteManager.shared.addRecent(hex: store.colorHex)
            }
        }
    }

    // MARK: 粗细

    private var widthControl: some View {
        Button {
            showWidthPopover.toggle()
        } label: {
            VStack(spacing: 2) {
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 16, height: max(1.5, min(6, store.lineWidth * 0.6)))
            }
            .frame(width: 26, height: 22)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Stroke Width"))
        .popover(isPresented: $showWidthPopover, arrowEdge: .bottom) {
            widthPopover
        }
    }

    private var widthPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "Stroke Width"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f", store.lineWidth))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $store.lineWidth, in: 1...24, step: 1)
                .frame(width: 180)
            HStack(spacing: 6) {
                ForEach([1, 2, 3, 5, 8, 12, 18] as [CGFloat], id: \.self) { value in
                    Button {
                        store.lineWidth = value
                    } label: {
                        Capsule()
                            .fill(store.lineWidth == value ? Color.accentColor : Color.primary.opacity(0.6))
                            .frame(width: 20, height: max(1.5, min(8, value * 0.6)))
                            .frame(height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .frame(width: 210)
    }

    // MARK: 字号

    private var fontControl: some View {
        Button {
            showFontPopover.toggle()
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Font Size"))
        .popover(isPresented: $showFontPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(localized: "Font Size"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f", store.fontSize))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $store.fontSize, in: 8...72, step: 1)
                    .frame(width: 180)
            }
            .padding(12)
            .frame(width: 210)
        }
    }
}
