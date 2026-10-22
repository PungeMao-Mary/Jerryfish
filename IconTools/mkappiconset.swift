import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let masterPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: masterPath) as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }

func downscale(_ image: CGImage, to size: Int) -> CGImage? {
    let w = size, h = size
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

func write(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

/// 小尺寸增强：图案本身是极淡的粉彩，缩到 16/32px 会糊成一团白。
/// 按 Apple「小尺寸仍需可辨识」的要求，对最小的两档做饱和度 + 轻微对比增强。
func enhanceForSmallSize(_ image: CGImage) -> CGImage? {
    let w = image.width, h = image.height
    var d = [UInt8](repeating: 0, count: w*h*4)
    guard let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    func luma(_ i: Int) -> Double {
        let a = Double(d[i+3]) / 255.0
        guard a > 0 else { return 1 }
        let r = Double(d[i]) / 255.0 / a, g = Double(d[i+1]) / 255.0 / a, b = Double(d[i+2]) / 255.0 / a
        return 0.299*r + 0.587*g + 0.114*b
    }

    // 取不透明像素的亮度分位数，避免个别像素带偏
    var samples: [Double] = []
    samples.reserveCapacity(w*h)
    for i in stride(from: 0, to: d.count, by: 4) where d[i+3] > 200 { samples.append(luma(i)) }
    samples.sort()
    guard samples.count > 8 else { return image }
    let lo = samples[Int(Double(samples.count) * 0.02)]
    let hi = samples[Int(Double(samples.count) * 0.98)]
    guard hi - lo > 0.01 else { return image }

    let floorLevel = 0.40      // 最暗的图案色压到 40%，底板保持接近白
    let saturation = 1.30

    for i in stride(from: 0, to: d.count, by: 4) {
        guard d[i+3] > 0 else { continue }
        let a = Double(d[i+3]) / 255.0
        var r = Double(d[i]) / 255.0 / a, g = Double(d[i+1]) / 255.0 / a, b = Double(d[i+2]) / 255.0 / a
        let l = 0.299*r + 0.587*g + 0.114*b
        let mapped = min(1.0, max(0.0, (l - lo) / (hi - lo))) * (1.0 - floorLevel) + floorLevel
        let gain = l > 0.0001 ? mapped / l : 1
        r *= gain; g *= gain; b *= gain
        let l2 = 0.299*r + 0.587*g + 0.114*b
        r = l2 + (r - l2) * saturation
        g = l2 + (g - l2) * saturation
        b = l2 + (b - l2) * saturation
        d[i]   = UInt8(min(255, max(0, min(max(r,0),1) * a * 255)))
        d[i+1] = UInt8(min(255, max(0, min(max(g,0),1) * a * 255)))
        d[i+2] = UInt8(min(255, max(0, min(max(b,0),1) * a * 255)))
    }
    return ctx.makeImage()
}

// 逐级折半降采样：比一步到位更锐利
var ladder: [Int: CGImage] = [master.width: master]
var current = master
var size = master.width
while size > 16 {
    let next = size / 2
    guard let scaled = downscale(current, to: next) else { break }
    ladder[next] = scaled
    current = scaled
    size = next
}

// macOS AppIcon 需要的全部尺寸
let plan: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in plan {
    var img = ladder[px] ?? downscale(master, to: px)
    if px <= 64, let base = img, let boosted = enhanceForSmallSize(base) { img = boosted }
    guard let final = img else {
        FileHandle.standardError.write(Data("scale failed for \(px)\n".utf8)); exit(2)
    }
    try write(final, to: "\(outDir)/\(name)")
    print("  \(name)  \(px)x\(px)\(px <= 64 ? "  (已增强小尺寸对比)" : "")")
}
print("母版尺寸: \(master.width)x\(master.height)")
