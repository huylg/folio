// Draws Folio's app icon and writes a complete .iconset.
//
//     swift Tools/MakeAppIcon.swift build/AppIcon.iconset
//
// The icon is drawn rather than exported from a design tool for the same reason the reading
// pane is dump-tested rather than pixel-diffed: the geometry is the source, and it is checked
// by rerunning it. `make icon` runs this and pipes the result through `iconutil`.
//
// The mark is the spread the app lays out — two pages of it, with the dashed rule that marks a
// page boundary in `DocumentStackView` running down the gutter. The blue is fixed at the macOS
// default accent: an icon cannot read `controlAccentColor`, so it cannot follow the app the way
// `Ink.accent` does.

import AppKit

// MARK: - Geometry

/// Artwork is authored in a 1024 square, then mapped into Apple's 824pt tile.
private let artSide: CGFloat = 1024
private let tileInset: CGFloat = 100
private let tileSide: CGFloat = artSide - tileInset * 2

/// How much of the interior survives at a given pixel size.
///
/// A page is 264 art units wide, which is 3.3px at 16 and 26px at 128 — so the rule count that
/// reads as text at 512 is a grey wash at 32. Three levels rather than one drawing scaled down.
enum Detail {
    case bare         // <= 16px
    case minimal      // 17...32px
    case simplified   // 33...64px
    case detailed     // >= 128px

    static func forPixelSize(_ px: Int) -> Detail {
        if px <= 16 { return .bare }
        if px <= 32 { return .minimal }
        if px <= 64 { return .simplified }
        return .detailed
    }
}

// MARK: - Palette
//
// Fixed values, unlike the app's dynamic `Ink`. `accentDeep` is the accent darkened 34%, the
// same figure the design canvas used, so the field has somewhere to go without reading as a
// gradient.

private let accent = CGColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)
private let accentDeep = CGColor(srgbRed: 0x07 / 255, green: 0x57 / 255, blue: 0xA8 / 255, alpha: 1)
private let paper = CGColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF6 / 255, alpha: 1)
private let headingInk = CGColor(srgbRed: 0x3E / 255, green: 0x4A / 255, blue: 0x58 / 255, alpha: 1)
private let bodyInk = CGColor(srgbRed: 0xA9 / 255, green: 0xB4 / 255, blue: 0xC1 / 255, alpha: 1)
private let gutterInk = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)

// MARK: - Squircle

/// A superellipse, not a rounded rectangle.
///
/// `CGPath(roundedRect:)` joins a straight edge to a circular arc, and the curvature break shows
/// at 512 and above against the continuous corners of every other icon in the Dock.
private func squircle(in rect: CGRect, exponent n: CGFloat = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let e = 2 / n

    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), e)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), e)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing helpers

private func rule(_ ctx: CGContext, from x1: CGFloat, to x2: CGFloat, y: CGFloat,
                  width: CGFloat, color: CGColor) {
    // Endpoints are ink extents: round caps overhang by half the width, so pull both in to keep
    // the left edge flush with the heading bar above it.
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: x1 + width / 2, y: y))
    ctx.addLine(to: CGPoint(x: x2 - width / 2, y: y))
    ctx.strokePath()
}

private func roundedBar(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

// MARK: - The icon

private func drawIcon(in ctx: CGContext, pixelSize: Int) {
    let detail = Detail.forPixelSize(pixelSize)
    let scale = CGFloat(pixelSize) / artSide

    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    // Author top-down, so these coordinates read the same as the design canvas.
    ctx.translateBy(x: 0, y: artSide)
    ctx.scaleBy(x: 1, y: -1)

    let tile = CGRect(x: tileInset, y: tileInset, width: tileSide, height: tileSide)
    let tilePath = squircle(in: tile)

    // Apple's icon shadow. Skipped below 128px, where a 20-unit blur is a smear rather than a lift.
    if detail == .detailed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 22,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.setFillColor(accentDeep)
        ctx.addPath(tilePath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [accent, accentDeep] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: tile.minX + tile.width * 0.1, y: tile.minY),
                           end: CGPoint(x: tile.minX + tile.width * 0.35, y: tile.maxY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Artwork was authored in the full 1024 square; map it into the tile.
    ctx.translateBy(x: tileInset, y: tileInset)
    ctx.scaleBy(x: tileSide / artSide, y: tileSide / artSide)

    let leftPage = CGRect(x: 196, y: 236, width: 264, height: 552)
    let rightPage = CGRect(x: 564, y: 236, width: 264, height: 552)

    if detail == .detailed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.20))
        for page in [leftPage, rightPage] {
            roundedBar(ctx, page, radius: 22, color: paper)
        }
        ctx.restoreGState()
    } else {
        for page in [leftPage, rightPage] {
            roundedBar(ctx, page, radius: detail == .simplified ? 20 : 14, color: paper)
        }
    }

    switch detail {
    case .detailed:
        roundedBar(ctx, CGRect(x: 232, y: 292, width: 150, height: 36), radius: 8, color: headingInk)
        // Both pages share one 56-unit baseline grid: on facing pages, rules that do not line
        // up across the gutter read as a mistake.
        for y in stride(from: CGFloat(392), through: 672, by: 56) {
            rule(ctx, from: 232, to: 424, y: y, width: 24, color: bodyInk)
        }
        rule(ctx, from: 232, to: 340, y: 728, width: 24, color: bodyInk)
        for y in stride(from: CGFloat(336), through: 672, by: 56) {
            rule(ctx, from: 600, to: 792, y: y, width: 24, color: bodyInk)
        }
        rule(ctx, from: 600, to: 704, y: 728, width: 24, color: bodyInk)

    case .simplified:
        roundedBar(ctx, CGRect(x: 232, y: 296, width: 150, height: 44), radius: 10, color: headingInk)
        for y in stride(from: CGFloat(420), through: 600, by: 90) {
            rule(ctx, from: 232, to: 424, y: y, width: 38, color: bodyInk)
        }
        rule(ctx, from: 232, to: 348, y: 690, width: 38, color: bodyInk)
        for y in stride(from: CGFloat(330), through: 600, by: 90) {
            rule(ctx, from: 600, to: 792, y: y, width: 38, color: bodyInk)
        }
        rule(ctx, from: 600, to: 700, y: 690, width: 38, color: bodyInk)

    case .bare:
        // A page is 3.3px across at 16. Anything inside it is haze that greys out the one thing
        // that still reads — that the pages are white. Only the heading bar earns its place.
        roundedBar(ctx, CGRect(x: 232, y: 300, width: 168, height: 64), radius: 14, color: headingInk)

    case .minimal:
        roundedBar(ctx, CGRect(x: 232, y: 296, width: 150, height: 52), radius: 12, color: headingInk)
        rule(ctx, from: 232, to: 424, y: 470, width: 56, color: bodyInk)
        rule(ctx, from: 232, to: 424, y: 590, width: 56, color: bodyInk)
        rule(ctx, from: 232, to: 340, y: 700, width: 56, color: bodyInk)
        for y in [CGFloat(380), 500, 620] {
            rule(ctx, from: 600, to: 792, y: y, width: 56, color: bodyInk)
        }
    }

    // The page boundary. At 16 and 32 the 104-unit gap between the pages already reads as the
    // divider, and an 18-unit rule on top of it is a quarter of a pixel of haze.
    if detail == .detailed || detail == .simplified {
        let width: CGFloat = detail == .detailed ? 18 : 26
        ctx.setStrokeColor(gutterInk)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: detail == .detailed ? [30, 24] : [50, 38])
        ctx.move(to: CGPoint(x: 512, y: 236))
        ctx.addLine(to: CGPoint(x: 512, y: 788))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    ctx.restoreGState()

    // Top-edge lift. Hero sizes only — 4 units is a sixteenth of a pixel at 16.
    if detail == .detailed {
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

// MARK: - Output

private func writePNG(pixelSize: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "MakeAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not create a \(pixelSize)px context"])
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    drawIcon(in: ctx, pixelSize: pixelSize)

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "MakeAppIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not snapshot the \(pixelSize)px context"])
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MakeAppIcon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "could not encode the \(pixelSize)px PNG"])
    }
    try data.write(to: url)
}

/// The ten files `iconutil` expects, and the pixel size each one is.
private let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

do {
    for entry in iconsetEntries {
        try writePNG(pixelSize: entry.pixels, to: outURL.appendingPathComponent(entry.name))
    }
    print("wrote \(iconsetEntries.count) images to \(outPath)")
} catch {
    FileHandle.standardError.write(Data("MakeAppIcon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
