import KeyboardShortcuts
import SwiftUI

// ============================================================
// 设置面板（Sheet）：全局快捷键录制 + 离线包状态 + 翻译偏好
// ============================================================

struct SettingsSheet: View {

    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var settings = UserSettingsManager.shared
    @State private var isDownloading = false
    @State private var downloadMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    shortcutSection
                    offlinePackSection
                    translationSection
                    pdfSection
                }
                .padding(20)
            }
            .frame(width: 460, height: 430)

            Divider()
            footer
        }
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "设置"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        section(title: String(localized: "全局快捷键")) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "截屏翻译"))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(String(localized: "在任意应用中按此快捷键框选文字并翻译"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyboardShortcuts.Recorder("", name: .captureAndTranslate)
                    .frame(width: 150)
            }

            HStack(spacing: 8) {
                Button(String(localized: "恢复默认 ⌘⇧A")) {
                    GlobalHotkeyManager.shared.restoreDefaultShortcut()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }

    // MARK: - 离线包

    private var offlinePackSection: some View {
        section(title: String(localized: "离线翻译语言包")) {
            HStack(spacing: 8) {
                Circle()
                    .fill(readinessColor)
                    .frame(width: 7, height: 7)
                Text(viewModel.engineReadiness.localizedDescription)
                    .font(.system(size: 12.5))
                Spacer()
                if isDownloading {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Button(downloadButtonTitle) {
                    Task { await download() }
                }
                .disabled(isDownloading)

                Button(String(localized: "在系统设置中管理")) {
                    ScreenCapturePermission.openTranslationSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

            if let downloadMessage {
                Text(downloadMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 应用能否自行发起语言资产下载；不能时引导用户去系统设置。
    private var downloadButtonTitle: String {
        viewModel.translationService.canRequestDownloads
            ? String(localized: "下载 / 修复离线语言包")
            : String(localized: "在系统设置中安装离线语言包")
    }

    private var readinessColor: Color {
        switch viewModel.engineReadiness {
        case .ready: return .green
        case .idle, .checking, .needsDownload: return .orange
        case .unsupported, .failed: return .red
        }
    }

    private func download() async {
        isDownloading = true
        downloadMessage = nil
        defer { isDownloading = false }
        let success = await viewModel.translationService.prepareOfflineLanguagePack()
        downloadMessage = success
            ? String(localized: "离线语言包已就绪。")
            : String(localized: "系统未确认安装完成。若刚才没有弹出下载提示，请在「系统设置 → 通用 → 语言与地区 → 翻译语言」中手动添加。")
    }

    // MARK: - 翻译偏好

    private var translationSection: some View {
        section(title: String(localized: "翻译偏好")) {
            Toggle(String(localized: "停止输入 1.5 秒后自动翻译"), isOn: $settings.translationAutoTranslateEnabled)
                .font(.system(size: 12.5))

            Toggle(String(localized: "截屏翻译结束后自动激活本应用窗口"), isOn: $settings.autoActivateOnCapture)
                .font(.system(size: 12.5))

            Toggle(String(localized: "显示性能耗时信息（调试用）"), isOn: $settings.showsPerformanceMetrics)
                .font(.system(size: 12.5))
        }
    }

    // MARK: - PDF

    private var pdfSection: some View {
        section(title: String(localized: "PDF 批注")) {
            Toggle(String(localized: "PDF 性能节约模式（低分辨率渲染，长文档更流畅）"),
                   isOn: $settings.pdfPerformanceSaverMode)
                .font(.system(size: 12.5))

            HStack {
                Text(String(localized: "译文批注字号"))
                    .font(.system(size: 12.5))
                Slider(value: $settings.pdfOverlayFontScale, in: 0.4...0.95)
                Text(String(format: "%.0f%%", settings.pdfOverlayFontScale * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            HStack {
                Button(String(localized: "屏幕录制权限设置")) {
                    ScreenCapturePermission.openSystemSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))            }
        }
    }

    // MARK: - 容器

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
        }
    }
}
