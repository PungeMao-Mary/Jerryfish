import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// Watches a saved screen region and updates only the translated glyph blocks.
/// Frames are sampled at 4 Hz; OCR waits for 500 ms of quiet when possible, but
/// starts after at most 1.5 seconds of continuous animation, with a 1 Hz ceiling.
@MainActor
final class PersistentTranslationController {

    private static let frameInterval = CMTime(value: 1, timescale: 4)
    private static let stableDelay: Duration = .milliseconds(500)
    private static let maximumStabilityDelay: Duration = .milliseconds(1_500)
    private static let minimumOCRInterval: Duration = .seconds(1)

    private let translationService: TranslationService
    private let onFailure: (AppFailure) -> Void
    private let onStatus: (String) -> Void
    private var sourceLanguage: TranslationSourceLanguage
    private var region: CGRect
    private var stream: SCStream?
    private var output: PersistentFrameOutput?
    private var overlayPanel: NSPanel?
    private var overlayIsShowingTranslations = false
    private var latestImage: CGImage?
    private var watchedRegions: [CGRect] = []
    private var glyphRegions: [CGRect] = []
    private var settledFingerprint: [UInt8]?
    private var settledGlyphFingerprint: [UInt8]?
    private var previousFrameFingerprint: [UInt8]?
    private var changeBurstStartedAt: ContinuousClock.Instant?
    private var lastMeaningfulChangeAt: ContinuousClock.Instant?
    private var lastRecognizedText = ""
    private var lastRecognizedLayout: [CGRect] = []
    private var lastTranslatedText = ""
    private var lastTranslatedBlocks: [PersistentTranslationBlock] = []
    private var lastOCRStart: ContinuousClock.Instant?
    private var generation = 0
    private var isRecognizing = false
    private var initialRecognitionPending = true
    private var pendingRecognitionGeneration: Int?
    private var stabilityTask: Task<Void, Never>?
    private var stabilityTaskID: UUID?
    private var translationTask: Task<Void, Never>?
    private var inFlightTranslation: (text: String, generation: Int, id: UUID)?
    private var isStopped = false

    init(
        region: CGRect,
        sourceLanguage: TranslationSourceLanguage,
        translationService: TranslationService,
        onStatus: @escaping (String) -> Void = { _ in },
        onFailure: @escaping (AppFailure) -> Void
    ) {
        self.region = region.standardized
        self.sourceLanguage = sourceLanguage
        self.translationService = translationService
        self.onStatus = onStatus
        self.onFailure = onFailure
    }

    func start() async throws {
        guard !isStopped else { throw CancellationError() }
        guard ScreenCaptureService.hasPermission() else {
            throw ScreenCaptureError.permissionDenied
        }
        guard let target = ScreenGeometry.display(containing: region) else {
            throw ScreenCaptureError.noDisplay
        }
        let displayRect = region.intersection(target.bounds)
        guard displayRect.width >= ScreenCaptureService.minimumSelectionSide,
              displayRect.height >= ScreenCaptureService.minimumSelectionSide else {
            throw ScreenCaptureError.emptySelection
        }
        region = displayRect

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !isStopped else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw ScreenCaptureError.noDisplay
        }

        showOverlay()
        let ownWindowIDs = Set(NSApp.windows.map(\.windowNumber).filter { $0 > 0 })
        let excluded = content.windows.filter { ownWindowIDs.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = ScreenGeometry.backingScaleFactor(forGlobalBounds: target.bounds)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: region.minX - target.bounds.minX,
            y: region.minY - target.bounds.minY,
            width: region.width,
            height: region.height
        )
        configuration.width = max(1, Int((region.width * scale).rounded()))
        configuration.height = max(1, Int((region.height * scale).rounded()))
        configuration.minimumFrameInterval = Self.frameInterval
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        configuration.captureResolution = .best

        let frameOutput = PersistentFrameOutput { [weak self] image in
            Task { @MainActor [weak self] in self?.consume(image) }
        }
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(frameOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Jerryfish.PersistentFrames", qos: .userInitiated))
        stream = newStream
        output = frameOutput
        onStatus("正在启动屏幕捕获…")
        try await newStream.startCapture()
        guard !isStopped else { throw CancellationError() }
    }

    func updateLanguage(_ language: TranslationSourceLanguage) {
        guard language != sourceLanguage else { return }
        sourceLanguage = language
        generation += 1
        stabilityTask?.cancel()
        stabilityTask = nil
        stabilityTaskID = nil
        translationTask?.cancel()
        inFlightTranslation = nil
        clearTranslations()
        watchedRegions = []
        glyphRegions = []
        settledFingerprint = nil
        settledGlyphFingerprint = nil
        previousFrameFingerprint = nil
        changeBurstStartedAt = nil
        lastMeaningfulChangeAt = nil
        lastRecognizedText = ""
        lastRecognizedLayout = []
        lastTranslatedText = ""
        lastTranslatedBlocks = []
        initialRecognitionPending = true
        if let latestImage {
            initialRecognitionPending = false
            beginRecognition(latestImage, generation: generation)
        }
    }

    func stop() {
        isStopped = true
        generation += 1
        stabilityTask?.cancel()
        translationTask?.cancel()
        stabilityTask = nil
        stabilityTaskID = nil
        translationTask = nil
        changeBurstStartedAt = nil
        lastMeaningfulChangeAt = nil
        inFlightTranslation = nil
        let currentStream = stream
        stream = nil
        output = nil
        overlayPanel?.orderOut(nil)
        overlayPanel?.close()
        overlayPanel = nil
        latestImage = nil
        Task {
            try? await currentStream?.stopCapture()
        }
    }

    private func showOverlay() {
        let frame = ScreenGeometry.toCocoa(region)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = makeOverlayView(blocks: [])
        overlayIsShowingTranslations = false
        overlayPanel = panel
        panel.orderFrontRegardless()
    }

    private func makeOverlayView(blocks: [PersistentTranslationBlock]) -> NSView {
        let view = NSHostingView(rootView: PersistentTranslationOverlay(regionSize: region.size, blocks: blocks))
        view.frame = CGRect(origin: .zero, size: region.size)
        view.autoresizingMask = [.width, .height]
        return view
    }

    private func clearTranslations() {
        guard overlayIsShowingTranslations else { return }
        overlayPanel?.contentView = makeOverlayView(blocks: [])
        overlayIsShowingTranslations = false
    }

    private func renderTranslations(_ blocks: [PersistentTranslationBlock]) {
        overlayPanel?.contentView = makeOverlayView(blocks: blocks)
        overlayIsShowingTranslations = !blocks.isEmpty
    }

    private func consume(_ image: CGImage) {
        latestImage = image
        if initialRecognitionPending {
            initialRecognitionPending = false
            settledFingerprint = Self.fingerprint(image, regions: watchedRegions)
            settledGlyphFingerprint = Self.fingerprint(image, regions: glyphRegions)
            previousFrameFingerprint = settledFingerprint
            onStatus("已捕获画面，正在识别\(sourceLanguage.title)文字…")
            beginRecognition(image, generation: generation)
            return
        }

        let fingerprint = Self.fingerprint(image, regions: watchedRegions)
        let previousFrameFingerprint = self.previousFrameFingerprint
        self.previousFrameFingerprint = fingerprint
        let glyphFingerprint = Self.fingerprint(image, regions: glyphRegions)
        let glyphChanged = settledGlyphFingerprint.map {
            Self.hasMeaningfulDifference(glyphFingerprint, from: $0)
        } ?? false
        if glyphChanged {
            clearTranslations()
        }
        guard let settledFingerprint else {
            self.settledFingerprint = fingerprint
            if !glyphChanged { return }
            changeBurstStartedAt = .now
            lastMeaningfulChangeAt = .now
            scheduleRecognition()
            return
        }
        let monitoredAreaChanged = Self.hasMeaningfulDifference(fingerprint, from: settledFingerprint)
        guard monitoredAreaChanged || glyphChanged else { return }

        let startsNewBurst = changeBurstStartedAt == nil
        if startsNewBurst { changeBurstStartedAt = .now }
        let recentChange = previousFrameFingerprint.map {
            Self.hasRecentDifference(fingerprint, from: $0)
        } ?? true
        if recentChange {
            lastMeaningfulChangeAt = .now
        } else if lastMeaningfulChangeAt == nil {
            lastMeaningfulChangeAt = .now
        }
        if startsNewBurst {
            onStatus("检测到画面变化，等待识别\(sourceLanguage.title)…")
        }
        scheduleRecognition()
    }

    private func scheduleRecognition() {
        guard stabilityTask == nil else { return }
        let taskID = UUID()
        stabilityTaskID = taskID
        stabilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let now = ContinuousClock.now
                let quietLongEnough = self.lastMeaningfulChangeAt.map {
                    $0.duration(to: now) >= Self.stableDelay
                } ?? true
                let animationWaitExpired = self.changeBurstStartedAt.map {
                    $0.duration(to: now) >= Self.maximumStabilityDelay
                } ?? true
                let rateLimitPassed = self.lastOCRStart.map {
                    $0.duration(to: now) >= Self.minimumOCRInterval
                } ?? true
                if (quietLongEnough || animationWaitExpired) && rateLimitPassed { break }
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard self.stabilityTaskID == taskID else { return }
            guard !Task.isCancelled, let latest = self.latestImage else {
                self.stabilityTaskID = nil
                self.stabilityTask = nil
                return
            }
            self.stabilityTaskID = nil
            self.stabilityTask = nil
            self.changeBurstStartedAt = nil
            self.lastMeaningfulChangeAt = nil
            self.settledFingerprint = Self.fingerprint(latest, regions: self.watchedRegions)
            self.settledGlyphFingerprint = Self.fingerprint(latest, regions: self.glyphRegions)
            self.previousFrameFingerprint = self.settledFingerprint
            self.beginRecognition(latest, generation: self.generation)
        }
    }

    private func beginRecognition(_ image: CGImage, generation expectedGeneration: Int) {
        guard !isRecognizing else {
            pendingRecognitionGeneration = expectedGeneration
            return
        }
        isRecognizing = true
        lastOCRStart = .now
        let service = VisionOCRService(configuration: .init(
            languages: [sourceLanguage.visionIdentifier],
            recognitionLevel: .accurate,
            usesLanguageCorrection: true,
            automaticallyDetectsLanguage: false
        ))

        Task { @MainActor [weak self] in
            defer {
                self?.isRecognizing = false
                self?.startPendingRecognitionIfNeeded()
            }
            guard let self else { return }
            let result: OCRResult
            do {
                result = try await service.recognize(cgImage: image)
            } catch let error as OCRError {
                guard self.generation == expectedGeneration else { return }
                self.watchedRegions = []
                self.glyphRegions = []
                self.settledFingerprint = Self.fingerprint(image, regions: [])
                self.settledGlyphFingerprint = self.settledFingerprint
                self.previousFrameFingerprint = self.settledFingerprint
                self.lastRecognizedText = ""
                self.lastRecognizedLayout = []
                self.lastTranslatedText = ""
                self.lastTranslatedBlocks = []
                if case .noTextFound = error {
                    self.clearTranslations()
                    self.onStatus("未识别到\(self.sourceLanguage.title)文字；请确认台词已显示且位于选区内。")
                    return
                }
                self.onStatus("OCR 失败：\(error.localizedDescription)")
                self.onFailure(.ocr(error.localizedDescription))
                return
            } catch {
                guard self.generation == expectedGeneration else { return }
                self.onStatus("OCR 失败：\(error.localizedDescription)")
                self.onFailure(.ocr(error.localizedDescription))
                return
            }

            guard self.generation == expectedGeneration else { return }
            let text = result.blocks.map(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.watchedRegions = Self.monitoringRegions(for: result.lines.map(\.boundingBox))
            self.glyphRegions = result.lines.map { Self.expanded($0.boundingBox) }
            let recognizedFingerprint = Self.fingerprint(image, regions: self.watchedRegions)
            self.settledFingerprint = recognizedFingerprint
            self.settledGlyphFingerprint = Self.fingerprint(image, regions: self.glyphRegions)
            self.previousFrameFingerprint = recognizedFingerprint

            // OCR may finish after another screen transition. Never paint its old
            // result over a newer frame; queue one fresh pass against the latest image.
            if let latest = self.latestImage,
               Self.hasMeaningfulDifference(
                   Self.fingerprint(latest, regions: self.watchedRegions),
                   from: recognizedFingerprint
               ) {
                self.previousFrameFingerprint = Self.fingerprint(latest, regions: self.watchedRegions)
                if self.changeBurstStartedAt == nil { self.changeBurstStartedAt = .now }
                if self.lastMeaningfulChangeAt == nil { self.lastMeaningfulChangeAt = .now }
                self.scheduleRecognition()
                return
            }

            let normalized = Self.normalized(text)
            guard !normalized.isEmpty else {
                self.lastRecognizedText = ""
                self.lastRecognizedLayout = []
                self.lastTranslatedText = ""
                self.lastTranslatedBlocks = []
                self.clearTranslations()
                self.onStatus("OCR 没有返回可翻译文本。")
                return
            }
            let layout = result.blocks.map(\.boundingBox)
            let layoutUnchanged = Self.sameLayout(layout, self.lastRecognizedLayout)
            if normalized == self.lastRecognizedText && layoutUnchanged {
                if self.lastTranslatedText == normalized, !self.lastTranslatedBlocks.isEmpty {
                    self.renderTranslations(self.lastTranslatedBlocks)
                    self.onStatus("译文已显示，正在监听文字变化。")
                    return
                }
                if self.inFlightTranslation?.text == normalized { return }
            }
            self.lastRecognizedText = normalized
            self.lastRecognizedLayout = layout
            self.clearTranslations()
            self.onStatus("已识别 \(result.blocks.count) 段文字，正在翻译…")
            self.translate(result.blocks, sourceText: normalized, generation: expectedGeneration)
        }
    }

    private func translate(_ sourceBlocks: [TextBlockGrouper.Block], sourceText: String, generation expectedGeneration: Int) {
        let requestID = UUID()
        inFlightTranslation = (sourceText, expectedGeneration, requestID)
        translationTask?.cancel()
        translationTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.inFlightTranslation?.id == requestID {
                    self.inFlightTranslation = nil
                }
            }
            guard let self else { return }
            do {
                let translations = try await self.translationService.batchTranslateStrict(texts: sourceBlocks.map(\.text))
                guard !Task.isCancelled, self.generation == expectedGeneration else { return }
                let blocks = zip(sourceBlocks, translations).compactMap { block, translation -> PersistentTranslationBlock? in
                    let value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return nil }
                    return PersistentTranslationBlock(rect: block.boundingBox, text: value, lineCount: block.lineCount)
                }
                self.lastTranslatedText = sourceText
                self.lastTranslatedBlocks = blocks
                if self.hasPendingVisualChange || self.lastRecognizedText != sourceText {
                    self.onStatus("画面仍在变化，等待确认最新文字…")
                } else if !blocks.isEmpty {
                    self.renderTranslations(blocks)
                    self.onStatus("已覆盖 \(blocks.count) 段译文，正在监听文字变化。")
                } else {
                    self.onStatus("翻译服务没有返回译文。")
                }
            } catch {
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                let failure = self.failure(from: error)
                self.onStatus("翻译失败：\(failure.message)")
                self.onFailure(failure)
            }
        }
    }

    private func startPendingRecognitionIfNeeded() {
        guard let expectedGeneration = pendingRecognitionGeneration,
              expectedGeneration == generation,
              latestImage != nil else {
            pendingRecognitionGeneration = nil
            return
        }
        pendingRecognitionGeneration = nil
        // A newer frame arrived while OCR was busy. Send one coalesced pass through
        // the same stability and rate gates instead of immediately starting OCR again.
        if changeBurstStartedAt == nil { changeBurstStartedAt = .now }
        if lastMeaningfulChangeAt == nil { lastMeaningfulChangeAt = .now }
        scheduleRecognition()
    }

    private var hasPendingVisualChange: Bool {
        stabilityTaskID != nil || changeBurstStartedAt != nil ||
            lastMeaningfulChangeAt != nil || isRecognizing ||
            pendingRecognitionGeneration != nil
    }

    private func failure(from error: Error) -> AppFailure {
        if let serviceError = error as? TranslationServiceError {
            switch serviceError {
            case .languagePackMissing: return .languagePackMissing
            case .engineNotReady: return .engineNotReady(translationService.diagnostics)
            default: return .translation(serviceError.localizedDescription)
            }
        }
        return .translation(error.localizedDescription)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expanded(_ rect: CGRect) -> CGRect {
        let verticalPadding = max(0.012, rect.height * 0.45)
        let horizontalPadding = max(0.006, rect.height * 0.2)
        return CGRect(
            x: max(0, rect.minX - horizontalPadding),
            y: max(0, rect.minY - verticalPadding),
            width: min(1, rect.width + horizontalPadding * 2),
            height: min(1, rect.height + verticalPadding * 2)
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Monitor a wide text band rather than only the last glyph bounds. This catches
    /// subtitles that move horizontally and dialogue that shifts within the selection.
    private static func monitoringRegions(for lineRects: [CGRect]) -> [CGRect] {
        guard let first = lineRects.first else { return [] }
        let bounds = lineRects.dropFirst().reduce(first) { $0.union($1) }
        let verticalPadding = max(0.035, bounds.height * 2)
        let minY = max(0, bounds.minY - verticalPadding)
        let maxY = min(1, bounds.maxY + verticalPadding)
        return [CGRect(x: 0, y: minY, width: 1, height: maxY - minY)]
    }

    private static func sameLayout(_ lhs: [CGRect], _ rhs: [CGRect]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            abs(left.minX - right.minX) < 0.015 &&
            abs(left.minY - right.minY) < 0.015 &&
            abs(left.width - right.width) < 0.03 &&
            abs(left.height - right.height) < 0.025
        }
    }

    private static func fingerprint(_ image: CGImage, regions: [CGRect]) -> [UInt8] {
        let width = 256
        let height = max(32, min(256, Int((CGFloat(width) * CGFloat(image.height) / CGFloat(image.width)).rounded())))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return [] }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let watched = regions.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : regions
            var result: [UInt8] = []
            result.reserveCapacity(width * height / 2)
            for y in 0..<height {
                for x in 0..<width {
                    let point = CGPoint(
                        x: (CGFloat(x) + 0.5) / CGFloat(width),
                        y: 1 - (CGFloat(y) + 0.5) / CGFloat(height)
                    )
                    guard watched.contains(where: { $0.contains(point) }) else { continue }
                    let offset = y * bytesPerRow + x * 4
                    let red = UInt16(buffer[offset])
                    let green = UInt16(buffer[offset + 1])
                    let blue = UInt16(buffer[offset + 2])
                    result.append(UInt8((red * 54 + green * 183 + blue * 19) / 256))
                }
            }
            return result
        }
    }

    private static func hasMeaningfulDifference(_ lhs: [UInt8], from rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return true }
        var changed = 0
        for index in lhs.indices where abs(Int(lhs[index]) - Int(rhs[index])) >= 10 {
            changed += 1
        }
        return changed >= 8 && Double(changed) / Double(lhs.count) >= 0.003
    }

    private static func hasRecentDifference(_ lhs: [UInt8], from rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return true }
        var changed = 0
        for index in lhs.indices where abs(Int(lhs[index]) - Int(rhs[index])) >= 3 {
            changed += 1
        }
        return changed >= 4 && Double(changed) / Double(lhs.count) >= 0.001
    }
}

private final class PersistentFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let imageHandler: @Sendable (CGImage) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(imageHandler: @escaping @Sendable (CGImage) -> Void) {
        self.imageHandler = imageHandler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        imageHandler(cgImage)
    }
}

private struct PersistentTranslationBlock: Identifiable {
    let id = UUID()
    var rect: CGRect
    var text: String
    var lineCount: Int
}

private struct PersistentTranslationOverlay: View {
    let regionSize: CGSize
    let blocks: [PersistentTranslationBlock]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(blocks) { block in
                let rect = CGRect(
                    x: block.rect.minX * regionSize.width,
                    y: block.rect.minY * regionSize.height,
                    width: block.rect.width * regionSize.width,
                    height: block.rect.height * regionSize.height
                )
                Text(block.text)
                    .font(.system(size: max(10, min(24, rect.height / CGFloat(max(1, block.lineCount)) * 0.88))))
                    .foregroundStyle(.white)
                    .lineLimit(max(1, block.lineCount + 1))
                    .minimumScaleFactor(0.68)
                    .frame(width: max(8, rect.width + 8), height: max(12, rect.height + 4), alignment: .topLeading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96))
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: regionSize.width, height: regionSize.height, alignment: .topLeading)
        .background(Color.clear)
        .allowsHitTesting(false)
    }
}
