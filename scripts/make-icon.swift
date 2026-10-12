// Builds the app icon from the logo and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// docs/logo.svg is the source artwork: the mark on a transparent background. The icon puts
// it on a light rounded square that follows the macOS icon grid.

import AppKit

let canvas: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
guard let logo = NSImage(contentsOf: root.appendingPathComponent("docs/logo.svg")) else {
    fatalError("cannot read docs/logo.svg")
}

func draw(in ctx: CGContext) {
    // Body of the icon: 824×824 inside the 1024 canvas, as in Apple's macOS grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0.98, 0.96, 0.94))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [rgb(1.00, 0.99, 0.97), rgb(0.95, 0.92, 0.89)] as CFArray,
        locations: [0, 1])!
    // Origin is bottom-left here: lighter at the top.
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The mark fills about 70% of the SVG's 256 box; drawn at 760 it spans ~520 px.
    let side: CGFloat = 760
    logo.draw(in: NSRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side))

    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0, 0, 0, 0.06))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(in: ctx)
    gc.flushGraphics()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let resources = root.appendingPathComponent("Resources")
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

print("Wrote Resources/AppIcon.icns")
