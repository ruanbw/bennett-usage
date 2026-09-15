#!/usr/bin/env swift
//
//  make-app-icon.swift — draws the Bennett Usage app icon and writes
//  packaging/AppIcon.icns (plus the .iconset used to build it).
//
//  Usage:
//    swift scripts/make-app-icon.swift                 # build the icon + .icns
//    swift scripts/make-app-icon.swift --variant bars  # pick a motif
//    swift scripts/make-app-icon.swift --preview /tmp/preview.png
//    swift scripts/make-app-icon.swift --export docs/icon.png:256
//    swift scripts/make-app-icon.swift --out /tmp/icons
//
//  Geometry is not invented: the plate size (816/1024), the superellipse
//  exponent (5.8) and the drop shadow were measured off the shipped macOS
//  system icons (Freeform / Music / Calculator / Activity Monitor all agree),
//  so this icon sits on the same grid as Apple's own.
//
//  Every size in the .iconset is rendered from the vector description at that
//  size rather than downsampled from the 1024 master, which keeps the 16/32 px
//  variants from turning to mush.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design constants (all in a 1024×1024 design space)

private enum Design {
    static let canvas: CGFloat = 1024
    /// Icon plate: 816/1024 = 0.7969, measured from Apple's system icons.
    static let plateInset: CGFloat = 104
    static let plateSide: CGFloat = canvas - plateInset * 2
    /// Superellipse exponent: the measured Apple silhouette (fill ratio 0.9617).
    static let plateExponent: CGFloat = 5.8

    /// Fitted against the shadow profile measured off Apple's system icons:
    /// this reproduces their decay curve to within 4/255 alpha.
    static let shadowOffsetY: CGFloat = 2
    static let shadowBlur: CGFloat = 52
    static let shadowAlpha: CGFloat = 0.33

    /// Plate gradient: matches the app's About card (accent blue → purple).
    static let plateTop = rgb(0x3D6BFF)
    static let plateBottom = rgb(0x8B36F0)
    static let plateMid = rgb(0x6450FA)

    static let sparkleColor = rgb(0xFFD35C)
    /// Below this size the sparkle turns into a smudge, so it is dropped —
    /// the same per-size simplification Apple applies to its own icons.
    static let sparkleMinimumSize = 64

    static let barCount = 3
    static let barWidth: CGFloat = 156
    static let barGap: CGFloat = 54
    static let barBaseline: CGFloat = 784
    static let barHeights: [CGFloat] = [248, 392, 536]
    static let barOpacities: [CGFloat] = [0.72, 0.86, 1.0]
}

private enum Variant: String {
    case bars
    case barsSparkle = "bars-sparkle"
    case ring

    static func parse(_ raw: String) -> Variant? { Variant(rawValue: raw) }
}

// MARK: - Helpers

private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func white(_ value: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: value, green: value, blue: value, alpha: alpha)
}

private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// Superellipse |x/a|^n + |y/b|^n = 1, sampled as a polygon. 2048 samples put
/// the chord error on a 816 px plate below 1/500 px, so the outline is smooth
/// at every size we render.
private func squirclePath(in rect: CGRect, exponent n: CGFloat, samples: Int = 2048) -> CGPath {
    let a = rect.width / 2
    let b = rect.height / 2
    let path = CGMutablePath()
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

private func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

/// Fills `path` with a linear gradient running between two points, in the
/// current (top-left origin) user space.
private func fillLinear(
    _ ctx: CGContext,
    path: CGPath,
    from: CGPoint,
    to: CGPoint,
    colors: [CGColor],
    locations: [CGFloat]
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors, locations), start: from, end: to, options: [])
    ctx.restoreGState()
}

private func fillRadial(
    _ ctx: CGContext,
    path: CGPath,
    center: CGPoint,
    radius: CGFloat,
    colors: [CGColor],
    locations: [CGFloat]
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient(colors, locations),
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

/// Four-pointed sparkle: tips on the axes, concave sides, the shape used by the
/// `sparkles` symbol in the menu bar.
private func sparklePath(center: CGPoint, radius r: CGFloat, waist: CGFloat = 0.30) -> CGPath {
    let path = CGMutablePath()
    let pull = CGPoint(x: center.x + r * waist, y: center.y - r * waist)
    let pullLeft = CGPoint(x: center.x - r * waist, y: center.y - r * waist)
    let pullDown = CGPoint(x: center.x - r * waist, y: center.y + r * waist)
    let pullRight = CGPoint(x: center.x + r * waist, y: center.y + r * waist)
    path.move(to: CGPoint(x: center.x, y: center.y - r))
    path.addCurve(
        to: CGPoint(x: center.x + r, y: center.y),
        control1: pull, control2: pull
    )
    path.addCurve(
        to: CGPoint(x: center.x, y: center.y + r),
        control1: pullRight, control2: pullRight
    )
    path.addCurve(
        to: CGPoint(x: center.x - r, y: center.y),
        control1: pullDown, control2: pullDown
    )
    path.addCurve(
        to: CGPoint(x: center.x, y: center.y - r),
        control1: pullLeft, control2: pullLeft
    )
    path.closeSubpath()
    return path
}

private func circlePath(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(
        x: center.x - radius, y: center.y - radius,
        width: radius * 2, height: radius * 2
    ), transform: nil)
}

// MARK: - The icon

/// Draws the icon into a `size`×`size` context whose user space has a top-left
/// origin and spans 0…1024 (the caller applies the flip and the scale).
/// `detailed` is false for the tiny variants, which drop the sparkle.
private func drawIcon(_ ctx: CGContext, variant: Variant, size: CGFloat, detailed: Bool) {
    let k = size / Design.canvas
    ctx.saveGState()
    ctx.scaleBy(x: k, y: k)

    let plate = CGRect(
        x: Design.plateInset, y: Design.plateInset,
        width: Design.plateSide, height: Design.plateSide
    )
    let platePath = squirclePath(in: plate, exponent: Design.plateExponent)

    // Drop shadow. Apple bakes a soft, slightly downward shadow into the icon
    // artwork itself; macOS does not add one at draw time.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: Design.shadowOffsetY),
        blur: Design.shadowBlur,
        color: rgb(0x000000, alpha: Design.shadowAlpha)
    )
    ctx.addPath(platePath)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    // Plate body.
    fillLinear(
        ctx, path: platePath,
        from: CGPoint(x: plate.minX, y: plate.minY),
        to: CGPoint(x: plate.maxX, y: plate.maxY),
        colors: [Design.plateTop, Design.plateMid, Design.plateBottom],
        locations: [0, 0.52, 1]
    )

    // Top-left sheen + bottom-right shading for a bit of glass depth.
    fillRadial(
        ctx, path: platePath,
        center: CGPoint(x: plate.minX + plate.width * 0.16, y: plate.minY + plate.height * 0.10),
        radius: plate.width * 0.95,
        colors: [white(1, 0.22), white(1, 0.0)],
        locations: [0, 1]
    )
    fillRadial(
        ctx, path: platePath,
        center: CGPoint(x: plate.maxX, y: plate.maxY),
        radius: plate.width * 0.75,
        colors: [rgb(0x1B0B4A, alpha: 0.28), rgb(0x1B0B4A, alpha: 0.0)],
        locations: [0, 1]
    )

    switch variant {
    case .bars, .barsSparkle:
        drawBars(ctx, plate: plate, detailed: detailed)
        if variant == .barsSparkle, detailed {
            // Floats in the open top-left corner, balancing the ascending bars
            // and echoing the `sparkles` symbol in the menu bar.
            ctx.addPath(sparklePath(center: CGPoint(x: 268, y: 268), radius: 92))
            ctx.setFillColor(Design.sparkleColor)
            ctx.fillPath()
        }
    case .ring:
        drawRing(ctx, plate: plate)
    }

    // Inner hairline border: keeps the plate edge crisp against light and dark
    // backgrounds alike.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.setStrokeColor(white(1, 0.16))
    ctx.setLineWidth(5)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

/// Ascending capsule bars — the dashboard's core chart idiom. At the tiny
/// sizes the ramp and the glass highlight only cost contrast, so the bars go
/// flat white instead.
private func drawBars(_ ctx: CGContext, plate: CGRect, detailed: Bool) {
    let layout = barsLayout(plate: plate)
    for (index, rect) in layout.enumerated() {
        let radius = rect.width / 2
        let path = CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        ctx.saveGState()
        if detailed {
            ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: rgb(0x140447, alpha: 0.28))
        }
        ctx.addPath(path)
        ctx.setFillColor(white(1, detailed ? Design.barOpacities[index] : 1))
        ctx.fillPath()
        ctx.restoreGState()

        guard detailed else { continue }

        // Glassy top: a light gradient so the capsules are not flat white.
        fillLinear(
            ctx, path: path,
            from: CGPoint(x: rect.minX, y: rect.minY),
            to: CGPoint(x: rect.minX, y: rect.maxY),
            colors: [white(1, 0.34), white(1, 0.0)],
            locations: [0, 1]
        )
    }
}

private func barsLayout(plate: CGRect) -> [CGRect] {
    let count = CGFloat(Design.barCount)
    let totalWidth = count * Design.barWidth + (count - 1) * Design.barGap
    let startX = plate.midX - totalWidth / 2
    return (0..<Design.barCount).map { index in
        let height = Design.barHeights[index]
        return CGRect(
            x: startX + CGFloat(index) * (Design.barWidth + Design.barGap),
            y: Design.barBaseline - height,
            width: Design.barWidth,
            height: height
        )
    }
}

/// Usage ring with a bright "today" arc and a small bar cluster inside.
private func drawRing(_ ctx: CGContext, plate: CGRect) {
    let center = CGPoint(x: plate.midX, y: plate.midY)
    let radius: CGFloat = 296
    let width: CGFloat = 104

    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)

    // Track.
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.setStrokeColor(white(1, 0.24))
    ctx.strokePath()

    // Value arc: 78% of the circle, starting at 12 o'clock, clockwise.
    let start = -CGFloat.pi / 2
    let sweep = CGFloat.pi * 2 * 0.78
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
    ctx.setStrokeColor(white(1, 1.0))
    ctx.strokePath()
    ctx.restoreGState()

    // Mini bars inside the ring.
    let heights: [CGFloat] = [120, 190, 264]
    let barWidth: CGFloat = 76
    let gap: CGFloat = 34
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let baseY = center.y + 152
    for (index, height) in heights.enumerated() {
        let rect = CGRect(
            x: center.x - total / 2 + CGFloat(index) * (barWidth + gap),
            y: baseY - height,
            width: barWidth,
            height: height
        )
        ctx.addPath(CGPath(
            roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil
        ))
        ctx.setFillColor(white(1, 0.55 + 0.15 * CGFloat(index)))
        ctx.fillPath()
    }
}

// MARK: - Rasterisation

private func renderIcon(variant: Variant, pixels: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create a \(pixels)px bitmap context")
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    // Flip to a top-left origin so the design maths reads top-down.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    drawIcon(ctx, variant: variant, size: CGFloat(pixels), detailed: pixels >= Int(Design.sparkleMinimumSize))
    guard let image = ctx.makeImage() else {
        fatalError("could not rasterise the \(pixels)px icon")
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
}

/// Sizes macOS wants in an .iconset: (filename, pixels).
private let iconsetSizes: [(String, Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

/// Contact sheet used to eyeball the icon at every size it will actually be
/// seen at, against light and dark backgrounds.
private func renderPreview(variant: Variant, to url: URL) {
    let sizes = [256, 128, 64, 32, 16]
    let margin: CGFloat = 48
    let gap: CGFloat = 40
    let rowHeight: CGFloat = 256 + 46
    let width = margin * 2 + CGFloat(sizes.count) * 256 + CGFloat(sizes.count - 1) * gap
    let height = margin * 2 + rowHeight * 2

    guard let ctx = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create the preview context") }
    ctx.interpolationQuality = .high

    // Light row on top, dark row below.
    ctx.setFillColor(rgb(0xF2F2F4))
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    ctx.setFillColor(rgb(0x1C1C1E))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))

    for row in 0..<2 {
        // The context is not flipped here, so row 0 lands in the lower half.
        let baseY = margin + CGFloat(row) * rowHeight
        var x = margin
        for size in sizes {
            let image = renderIcon(variant: variant, pixels: size)
            let box = CGRect(
                x: x + (256 - CGFloat(size)) / 2,
                y: baseY + (256 - CGFloat(size)) / 2,
                width: CGFloat(size),
                height: CGFloat(size)
            )
            ctx.draw(image, in: box)
            x += 256 + gap
        }
    }

    guard let image = ctx.makeImage() else { fatalError("could not rasterise the preview") }
    writePNG(image, to: url)
}

// MARK: - CLI

private func run(_ launchPath: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        FileHandle.standardError.write("error: \(launchPath) \(arguments.joined(separator: " ")) failed\n".data(using: .utf8)!)
        exit(1)
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(2)
}

private var arguments = Array(CommandLine.arguments.dropFirst())
private var variant = Variant.barsSparkle
private var outDir = "packaging"
private var previewPath: String?
private var exportPath: String?
private var exportSize = 1024
private var keepIconset = false

while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--variant":
        guard let value = arguments.first, let parsed = Variant.parse(value) else {
            fail("--variant needs one of: bars, bars-sparkle, ring")
        }
        arguments.removeFirst()
        variant = parsed
    case "--out":
        guard let value = arguments.first else { fail("--out needs a directory") }
        arguments.removeFirst()
        outDir = value
    case "--preview":
        guard let value = arguments.first else { fail("--preview needs a path") }
        arguments.removeFirst()
        previewPath = value
    case "--export":
        guard let value = arguments.first else { fail("--export needs PATH[:SIZE]") }
        arguments.removeFirst()
        let parts = value.split(separator: ":", maxSplits: 1)
        exportPath = String(parts[0])
        if parts.count > 1 {
            guard let size = Int(parts[1]), size >= 16, size <= 4096 else {
                fail("--export size must be 16…4096")
            }
            exportSize = size
        }
    case "--keep-iconset":
        keepIconset = true
    case "-h", "--help":
        print("usage: swift scripts/make-app-icon.swift [--variant bars|bars-sparkle|ring] [--out DIR] [--preview PATH] [--keep-iconset]")
        exit(0)
    default:
        fail("unknown option: \(argument)")
    }
}

let fileManager = FileManager.default
let outURL = URL(fileURLWithPath: outDir)
let iconsetURL = outURL.appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (name, pixels) in iconsetSizes {
    writePNG(renderIcon(variant: variant, pixels: pixels), to: iconsetURL.appendingPathComponent("\(name).png"))
}

let icnsURL = outURL.appendingPathComponent("AppIcon.icns")
try? fileManager.removeItem(at: icnsURL)
run("/usr/bin/iconutil", ["-c", "icns", iconsetURL.path, "-o", icnsURL.path])

if let previewPath {
    renderPreview(variant: variant, to: URL(fileURLWithPath: previewPath))
}

if let exportPath {
    writePNG(renderIcon(variant: variant, pixels: exportSize), to: URL(fileURLWithPath: exportPath))
}

print("==> \(icnsURL.path) (\(variant.rawValue))")
if !keepIconset {
    try? fileManager.removeItem(at: iconsetURL)
} else {
    print("==> \(iconsetURL.path)")
}
if let previewPath {
    print("==> \(previewPath)")
}
if let exportPath {
    print("==> \(exportPath) (\(exportSize)px)")
}
