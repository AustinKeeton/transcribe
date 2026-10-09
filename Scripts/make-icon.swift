// Draws the app icon (light, dark and tinted) into App/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root: swift Scripts/make-icon.swift
import AppKit
import CoreGraphics

let size = 1024.0
let outDir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")

enum Style { case light, dark, tinted }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(_ style: Style) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: size)   // draw with y pointing down
    ctx.scaleBy(x: 1, y: -1)

    // Background
    switch style {
    case .light:
        let g = CGGradient(colorsSpace: space, colors: [rgb(0x4B4FE8), rgb(0x8A3BE6)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size, y: size), options: [])
    case .dark:
        let g = CGGradient(colorsSpace: space, colors: [rgb(0x15162B), rgb(0x0B0B14)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size, y: size), options: [])
    case .tinted:
        ctx.setFillColor(rgb(0x000000))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    func capsule(_ r: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2,
                           cornerHeight: min(r.width, r.height) / 2, transform: nil))
        ctx.fillPath()
    }

    let mid = size / 2
    // Sound: waveform bars, tallest in the middle-left, shrinking toward the text.
    let heights: [Double] = [180, 340, 500, 380, 270, 160, 84]
    let barWidth = 40.0, gap = 22.0, textGap = 34.0
    let lines: [(dy: Double, width: Double)] = [(-120, 200), (-40, 240), (40, 168), (120, 210)]
    // Centre the whole design: bars, gap, then the widest text line.
    let total = Double(heights.count) * barWidth + Double(heights.count - 1) * gap + textGap
        + lines.map(\.width).max()!
    var x = (size - total) / 2
    for (i, h) in heights.enumerated() {
        let color: CGColor
        switch style {
        case .light: color = rgb(0xFFFFFF)
        case .dark:
            // Blue into orange through purple and pink (a straight blend goes grey).
            let t = Double(i) / Double(heights.count - 1)
            let hue = (220 + 170 * t).truncatingRemainder(dividingBy: 360) / 360
            color = NSColor(hue: hue, saturation: 0.72, brightness: 1, alpha: 1).cgColor
        case .tinted: color = rgb(0xFFFFFF)
        }
        capsule(CGRect(x: x, y: mid - h / 2, width: barWidth, height: h), color)
        x += barWidth + gap
    }

    // Text: lines of transcript.
    let lineX = x - gap + textGap, lineH = 40.0
    for (i, line) in lines.enumerated() {
        let color: CGColor
        switch style {
        case .light: color = rgb(0xFFFFFF, 0.92)
        case .dark: color = rgb(0xEDEBFF, 0.92)
        case .tinted: color = rgb(0xFFFFFF, i == 0 ? 1 : 0.75)
        }
        capsule(CGRect(x: lineX, y: mid + line.dy - lineH / 2, width: line.width, height: lineH), color)
    }

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try draw(.light).write(to: outDir.appending(path: "AppIcon.png"))
try draw(.dark).write(to: outDir.appending(path: "AppIcon-Dark.png"))
try draw(.tinted).write(to: outDir.appending(path: "AppIcon-Tinted.png"))
print("wrote icons to \(outDir.path)")
