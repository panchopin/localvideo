// Generates the app icon as a 1024×1024 PNG. Run: swift make_icon.swift out.png
// A dark rounded-square ("squircle-ish") with a white video-camera glyph and a
// green "live" dot — echoing the app's status indicators.
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

// --- Background squircle with a vertical dark-slate gradient ---
let inset = S * 0.05
let bgRect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: (S - 2 * inset) * 0.225,
                    cornerHeight: (S - 2 * inset) * 0.225, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: space,
                      colors: [CGColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1),
                               CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// --- Camera body (white rounded rectangle) ---
let bodyX = S * 0.27, bodyY = S * 0.37
let bodyW = S * 0.34, bodyH = S * 0.26
ctx.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1))
ctx.addPath(CGPath(roundedRect: CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH),
                   cornerWidth: S * 0.045, cornerHeight: S * 0.045, transform: nil))
ctx.fillPath()

// --- Lens nub (trapezoid on the right, classic camcorder shape) ---
let nubX = bodyX + bodyW + S * 0.004
ctx.beginPath()
ctx.move(to: CGPoint(x: nubX, y: bodyY + bodyH * 0.30))
ctx.addLine(to: CGPoint(x: nubX + S * 0.115, y: bodyY + bodyH * 0.06))
ctx.addLine(to: CGPoint(x: nubX + S * 0.115, y: bodyY + bodyH * 0.94))
ctx.addLine(to: CGPoint(x: nubX, y: bodyY + bodyH * 0.70))
ctx.closePath()
ctx.fillPath()

// --- Lens (dark) with a green "live" dot in its center ---
let lensCenter = CGPoint(x: bodyX + bodyW * 0.32, y: bodyY + bodyH * 0.5)
let lensR = bodyH * 0.30
ctx.setFillColor(CGColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 1))
ctx.fillEllipse(in: CGRect(x: lensCenter.x - lensR, y: lensCenter.y - lensR, width: lensR * 2, height: lensR * 2))
let dotR = lensR * 0.42
ctx.setFillColor(CGColor(red: 0.20, green: 0.80, blue: 0.35, alpha: 1))
ctx.fillEllipse(in: CGRect(x: lensCenter.x - dotR, y: lensCenter.y - dotR, width: dotR * 2, height: dotR * 2))

// --- Write PNG ---
guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
