import SwiftUI

// ============================================================
// 主窗口
//
// ┌────────────────────────────────────────────────────────┐
// │              [TextEditor 大输入框]                      │
// ├───────────────────┬───────────────────┬────────────────┤
// │      [ 打开 ]     │    [ 翻译 ]       │    [ 设置 ]    │
// └───────────────────┴───────────────────┴────────────────┘
// ============================================================

struct MainTranslatorView: View {

    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var settings = UserSettingsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            engineBar
            Divider()
            editorArea
            Divider()
            actionBar
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Color.locus(.textBackground))
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            SettingsSheet(viewModel: viewModel)
        }
        .alert(
            viewModel.lastError?.title ?? "",
            isPresented: Binding(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.lastError = nil } }
            ),
            presenting: viewModel.lastError
        ) { failure in
            if let recovery = failure.recovery {
                Button(recovery.title) { viewModel.performRecovery(recovery) }
            }
            Button(String(localized: "关闭"), role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .onAppear {
            Task { await viewModel.bootstrapEngine() }
        }
        .onChange(of: viewModel.inputText) { _, _ in
            // 停止输入 3 秒后自动翻译（可在设置中关闭）
            viewModel.inputTextDidChange()
        }
        .onChange(of: settings.sourceLanguage) { _, _ in
            Task { await viewModel.sourceLanguageDidChange() }
        }
        .onChange(of: viewModel.activePDFURL) { _, newValue in
            guard newValue != nil else { return }
            openWindow(id: "pdf")
        }
    }

    // MARK: - 顶部引擎状态条

    private var engineBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(readinessColor)
                .frame(width: 7, height: 7)

            Text(viewModel.engineReadiness.localizedDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let status = viewModel.persistentTranslationStatus {
                Text("· \(status)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(status)
            }

            if settings.showsPerformanceMetrics,
               viewModel.translationService.lastLatencyMilliseconds > 0 {
                Text(String(format: "· 最近 %.0f ms", viewModel.translationService.lastLatencyMilliseconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if let warmUp = viewModel.ocrWarmUpState.localizedDescription {
                Text(warmUp)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.orange.opacity(0.12)))
            }

            Spacer(minLength: 0)

            Picker(String(localized: "识别语言"), selection: $settings.sourceLanguage) {
                ForEach(TranslationSourceLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(String(localized: "选择原文语言"))

            if case .needsDownload = viewModel.engineReadiness {
                Button(String(localized: "下载离线语言包")) {
                    Task { await viewModel.downloadLanguagePack() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var readinessColor: Color {
        switch viewModel.engineReadiness {
        case .ready: return .green
        case .idle, .checking, .needsDownload: return .orange
        case .unsupported, .failed: return .red
        }
    }

    // MARK: - 编辑区（原文 / 译文 始终对照）

    private var editorArea: some View {
        HStack(spacing: 0) {
            editorColumn(
                title: settings.sourceLanguage == .english
                    ? String(localized: "英文原文")
                    : String(localized: "日文原文"),
                text: $viewModel.inputText,
                placeholder: settings.sourceLanguage == .english
                    ? String(localized: "在此粘贴英文内容，或按 ⌘⇧A 截屏取词…")
                    : String(localized: "在此粘贴日文内容，或按 ⌘⇧A 截屏取词…"),
                isEditable: true,
                autoFocus: true
            )

            Divider()

            editorColumn(
                title: String(localized: "中文译文"),
                text: $viewModel.translatedText,
                placeholder: String(localized: "译文将在此显示，可自由编辑 / 复制"),
                isEditable: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .center) {
            if viewModel.showsBusyIndicator {
                busyOverlay
            }
        }
    }

    private func editorColumn(
        title: String,
        text: Binding<String>,
        placeholder: String,
        isEditable: Bool,
        autoFocus: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(text.wrappedValue.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // 占位符由 NSTextView 在文字排版原点自行绘制，天然与光标严格对齐
            AcademicTextEditor(
                text: text,
                placeholder: placeholder,
                isEditable: isEditable,
                autoFocus: autoFocus
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.locus(.textBackground))
    }

    private var busyOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(viewModel.activityLabel.isEmpty ? String(localized: "处理中…") : viewModel.activityLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    // MARK: - 底部三按钮

    /// 底部操作区：
    ///
    ///                  [ 翻译 ]          ← 主操作，独占一行（强调色）
    ///      [ 截屏 ] ｜ [ 常驻翻译 ] ｜ [ 打开 ] ｜ [ 设置 ]
    private var actionBar: some View {
        VStack(spacing: 0) {
            primaryTranslateButton
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
            secondaryActionRow
        }
        .background(Color.locus(.toolbarBackground))
        .overlay(alignment: .top) {
            if settings.showsPerformanceMetrics, let timings = viewModel.timings {
                Text(timings.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                    .offset(y: -9)
            }
        }
    }

    private var primaryTranslateButton: some View {
        Button {
            Task { await viewModel.translateCurrentInput() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "translate")
                    .font(.system(size: 15, weight: .semibold))
                Text(String(localized: "翻译"))
                    .font(.system(size: 14.5, weight: .semibold))
                Text(String(localized: "翻译当前内容 ⌘↩"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.white)
        .background(Color.accentColor)
        .frame(height: 42)
        .disabled(viewModel.isBusy)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private var secondaryActionRow: some View {
        HStack(spacing: 0) {
            bottomButton(
                title: String(localized: "截屏"),
                subtitle: String(localized: "框选区域就地翻译 ⌘⇧A"),
                icon: "viewfinder"
            ) {
                viewModel.beginCaptureFlow()
            }

            verticalDivider

            bottomButton(
                title: viewModel.isPersistentTranslationActive ? String(localized: "停止常驻") : String(localized: "常驻翻译"),
                subtitle: viewModel.isPersistentTranslationActive
                    ? String(localized: "停止屏幕监听")
                    : String(localized: "自动替换选区文字 ⌘+点击重选"),
                icon: viewModel.isPersistentTranslationActive ? "stop.fill" : "text.viewfinder"
            ) {
                viewModel.handlePersistentTranslationClick(commandHeld: NSEvent.modifierFlags.contains(.command))
            }

            verticalDivider

            bottomButton(
                title: String(localized: "打开"),
                subtitle: String(localized: "导入 PDF 翻译"),
                icon: "doc.text.magnifyingglass"
            ) {
                viewModel.choosePDFAndOpen()
            }

            verticalDivider

            bottomButton(
                title: String(localized: "设置"),
                subtitle: String(localized: "快捷键 / 偏好"),
                icon: "slider.horizontal.3"
            ) {
                viewModel.isSettingsPresented = true
            }
        }
        .frame(height: 52)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 32)
    }

    private func bottomButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.primary)
    }
}

#Preview {
    MainTranslatorView(viewModel: AppViewModel())
        .frame(width: 900, height: 600)
}
