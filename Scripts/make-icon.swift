#!/usr/bin/env swift
// Generates Resources/AppIcon.icns from a programmatic outline-style glyph
// (a shield with a checkmark). No external assets/tools beyond iconutil.
// Run from the repo root:  swift Scripts/make-icon.swift
import Foundation
import CoreGraphics
import ImageIO

let REF: CGFloat = 1024

func draw(_ px: Int) -> CGImage {
    let S = CGFloat(px)
    let f = S / REF
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Use top-left origin with y growing downward.
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * f, y: y * f) }

    // Rounded-square tile with a vertical blue gradient.
    let m: CGFloat = 80 * f
    let rect = CGRect(x: m, y: m, width: S - 2*m, height: S - 2*m)
    let radius = rect.width * 0.2237
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.36, green: 0.61, blue: 0.84, alpha: 1),   // top
        CGColor(srgbRed: 0.18, green: 0.42, blue: 0.69, alpha: 1),   // bottom
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: m),
                           end: CGPoint(x: S/2, y: S - m), options: [])
    ctx.restoreGState()

    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))

    // Shield outline.
    let rr: CGFloat = 40
    let shield = CGMutablePath()
    shield.move(to: P(302 + rr, 300))
    shield.addLine(to: P(722 - rr, 300))
    shield.addQuadCurve(to: P(722, 300 + rr), control: P(722, 300))
    shield.addLine(to: P(722, 470))
    shield.addQuadCurve(to: P(512, 760), control: P(722, 648))
    shield.addQuadCurve(to: P(302, 470), control: P(302, 648))
    shield.addLine(to: P(302, 300 + rr))
    shield.addQuadCurve(to: P(302 + rr, 300), control: P(302, 300))
    shield.closeSubpath()
    ctx.addPath(shield)
    ctx.setLineWidth(46 * f)
    ctx.strokePath()

    // Checkmark inside the shield.
    let check = CGMutablePath()
    check.move(to: P(424, 512))
    check.addLine(to: P(488, 584))
    check.addLine(to: P(612, 430))
    ctx.addPath(check)
    ctx.setLineWidth(56 * f)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: work)
try! fm.createDirectory(at: work, withIntermediateDirectories: true)

var cache: [Int: CGImage] = [:]
for (name, px) in entries {
    let img = cache[px] ?? draw(px)
    cache[px] = img
    writePNG(img, to: work.appendingPathComponent(name))
}

// Compose the .icns.
try! fm.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", work.path, "-o", "Resources/AppIcon.icns"]
try! proc.run()
proc.waitUntilExit()
print(proc.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
print("Preview: \(work.appendingPathComponent("icon_512x512.png").path)")
