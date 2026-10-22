import CoreGraphics
import XCTest
@testable import Jerryfish

// ============================================================
// 截屏「窗口点选」的命中测试与坐标换算
// ============================================================

final class CaptureWindowSnapperTests: XCTestCase {

    private func candidate(_ id: Int, _ rect: CGRect, _ name: String = "App") -> CaptureWindowCandidate {
        CaptureWindowCandidate(id: id, bounds: rect, ownerName: name)
    }

    func testHitTestPicksFrontmostCandidate() {
        // 列表顺序即「前 → 后」
        let front = candidate(1, CGRect(x: 100, y: 100, width: 300, height: 200), "Front")
        let back = candidate(2, CGRect(x: 0, y: 0, width: 1000, height: 800), "Back")
        let hit = CaptureWindowSnapper.hitTest(CGPoint(x: 200, y: 200), in: [front, back])
        XCTAssertEqual(hit?.id, 1, "重叠时应选中列表靠前（视觉在上）的窗口")
    }

    func testHitTestReturnsNilWhenNoWindowContainsPoint() {
        let only = candidate(1, CGRect(x: 10, y: 10, width: 100, height: 100))
        XCTAssertNil(CaptureWindowSnapper.hitTest(CGPoint(x: 500, y: 500), in: [only]))
        XCTAssertNil(CaptureWindowSnapper.hitTest(CGPoint(x: 0, y: 0), in: []))
    }

    func testHitTestPrefersSmallestWindow() {
        let big = candidate(1, CGRect(x: 0, y: 0, width: 1000, height: 800), "Big")
        let small = candidate(2, CGRect(x: 200, y: 200, width: 200, height: 150), "Small")
        // 用户点在小窗口上时，应该选小窗口而不是盖住它的大窗口
        XCTAssertEqual(CaptureWindowSnapper.hitTestPreferringSmallest(CGPoint(x: 250, y: 250), in: [big, small])?.id, 2)
        // 点在大窗口独有区域则选大窗口
        XCTAssertEqual(CaptureWindowSnapper.hitTestPreferringSmallest(CGPoint(x: 800, y: 700), in: [big, small])?.id, 1)
        XCTAssertNil(CaptureWindowSnapper.hitTestPreferringSmallest(CGPoint(x: 2000, y: 2000), in: [big, small]))
    }

    func testAreaIsAlwaysNonNegative() {
        XCTAssertEqual(candidate(1, CGRect(x: 0, y: 0, width: 30, height: 4)).area, 120)
        XCTAssertEqual(candidate(1, CGRect(x: 0, y: 0, width: 0, height: 400)).area, 0)
        // 负宽度是非法输入，但面积绝不能变成负数（否则「取最小面积」会选错窗口）
        XCTAssertGreaterThanOrEqual(candidate(1, CGRect(x: 0, y: 0, width: -10, height: 5)).area, 0)
    }

    // MARK: 坐标换算（纯函数，确定性）

    func testLocalizeIsPureTranslation() {
        let origin = CGPoint(x: 120, y: 60)
        let global = CGRect(x: 500, y: 300, width: 800, height: 600)
        let local = CaptureWindowSnapper.localize(global, panelOrigin: origin)
        XCTAssertEqual(local.minX, 380)
        XCTAssertEqual(local.minY, 240)
        XCTAssertEqual(local.width, 800)
        XCTAssertEqual(local.height, 600)

        // 负原点（多显示器主屏左侧）也要正确
        let negative = CaptureWindowSnapper.localize(global, panelOrigin: CGPoint(x: -1920, y: -200))
        XCTAssertEqual(negative.minX, 2420)
        XCTAssertEqual(negative.minY, 500)

        // 零原点即恒等
        XCTAssertEqual(CaptureWindowSnapper.localize(global, panelOrigin: .zero), global)
    }

    // MARK: 与真实窗口服务器交互（只断言与窗口位置无关的性质）

    func testLiveCandidatesAreSane() throws {
        let candidates = CaptureWindowSnapper.candidates(panelOrigin: .zero, excludingPIDs: [])
        try XCTSkipIf(candidates.isEmpty, "当前环境没有可枚举的普通窗口")

        for candidate in candidates {
            XCTAssertFalse(candidate.ownerName.isEmpty)
            XCTAssertGreaterThan(candidate.bounds.width, 0)
            XCTAssertGreaterThan(candidate.bounds.height, 0)
            XCTAssertGreaterThan(candidate.area, 0)
            // 普通窗口不应离谱地超出整个桌面范围
            XCTAssertLessThan(candidate.bounds.width, 20_000)
            XCTAssertLessThan(candidate.bounds.height, 20_000)
        }

        // 极端 minimumSide 必须把所有窗口过滤掉（过滤器确实生效）
        XCTAssertTrue(CaptureWindowSnapper.candidates(panelOrigin: .zero, excludingPIDs: [],
                                                     minimumSide: 100_000).isEmpty)
    }
}
