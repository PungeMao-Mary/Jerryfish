import AppKit
import WebKit

// 用 WKWebView 渲染 SVG → 透明背景 PNG（支持渐变/滤镜；Quick Look 会把背景填成白色，不可用）
final class NavDelegate: NSObject, WKNavigationDelegate {
    var loaded = false
    var failed: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 给 SVG 滤镜/模糊一点光栅化时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.loaded = true }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed = error.localizedDescription
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed = error.localizedDescription
    }
}

let svgPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let side = CGFloat(Int(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "1024") ?? 1024)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let config = WKWebViewConfiguration()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: side, height: side), configuration: config)
webView.underPageBackgroundColor = .clear
webView.setValue(false, forKey: "drawsBackground")

let delegate = NavDelegate()
webView.navigationDelegate = delegate

// WebKit 需要有窗口才会构建渲染树；放在屏幕外避免打扰
let window = NSWindow(contentRect: NSRect(x: -side - 200, y: 0, width: side, height: side),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isOpaque = false
window.backgroundColor = .clear
window.contentView = webView
window.orderBack(nil)

webView.loadFileURL(URL(fileURLWithPath: svgPath),
                    allowingReadAccessTo: URL(fileURLWithPath: svgPath).deletingLastPathComponent())

func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}
pump(3.0)
if let f = delegate.failed { FileHandle.standardError.write(Data("load failed: \(f)\n".utf8)); exit(2) }

let snapConfig = WKSnapshotConfiguration()
snapConfig.rect = CGRect(x: 0, y: 0, width: side, height: side)
var snapshot: NSImage?
var done = false
webView.takeSnapshot(with: snapConfig) { image, error in
    if let error { FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8)) }
    snapshot = image
    done = true
}
let deadline = Date().addingTimeInterval(15)
while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
guard let snapshot else { FileHandle.standardError.write(Data("no snapshot\n".utf8)); exit(3) }

guard let cg = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("no cgImage\n".utf8)); exit(4)
}
let rep = NSBitmapImageRep(cgImage: cg)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(5) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("rendered \(cg.width)x\(cg.height) → \(outPath)")
exit(0)
