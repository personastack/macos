#!/usr/bin/swift
import AppKit
import CoreGraphics
import Foundation

let width = 740
let height = 500
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width * 2,
        pixelsHigh: height * 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
  fatalError("Usage: render-dmg-background.swift <output.png>")
}
let context = graphicsContext.cgContext

let colors = [
  CGColor(red: 0.035, green: 0.055, blue: 0.12, alpha: 1),
  CGColor(red: 0.025, green: 0.035, blue: 0.085, alpha: 1),
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!

context.saveGState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
context.scaleBy(x: 2, y: 2)
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])

func drawGlow(at center: CGPoint, radius: CGFloat, color: CGColor) {
  let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color, color.copy(alpha: 0)] as CFArray, locations: [0, 1])!
  context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

drawGlow(at: CGPoint(x: 88, y: 318), radius: 220, color: CGColor(red: 0.04, green: 0.23, blue: 0.72, alpha: 0.31))
drawGlow(at: CGPoint(x: 660, y: 210), radius: 240, color: CGColor(red: 0.08, green: 0.13, blue: 0.54, alpha: 0.22))

context.setStrokeColor(CGColor(red: 0.31, green: 0.49, blue: 0.94, alpha: 0.13))
context.setLineWidth(1)
for (center, radius) in [(CGPoint(x: 640, y: 395), CGFloat(122)), (CGPoint(x: 100, y: 86), CGFloat(94))] {
  context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  context.strokeEllipse(in: CGRect(x: center.x - radius + 18, y: center.y - radius + 18, width: (radius - 18) * 2, height: (radius - 18) * 2))
}

let stars: [(CGFloat, CGFloat, CGFloat)] = [
  (38, 418, 2), (120, 375, 1.5), (232, 430, 1.5), (344, 389, 1),
  (478, 433, 2), (700, 345, 1.5), (61, 175, 1.5), (676, 105, 2),
  (390, 120, 1.5), (278, 76, 1), (528, 75, 1.5),
]
for (x, y, radius) in stars {
  context.setFillColor(CGColor(red: 0.55, green: 0.69, blue: 1, alpha: 0.58))
  context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}

context.setStrokeColor(CGColor(red: 0.31, green: 0.56, blue: 1, alpha: 0.82))
context.setLineWidth(3)
context.setLineCap(.round)
context.move(to: CGPoint(x: 295, y: 250))
context.addLine(to: CGPoint(x: 445, y: 250))
context.strokePath()
context.setFillColor(CGColor(red: 0.39, green: 0.64, blue: 1, alpha: 0.95))
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 445, y: 250))
arrow.addLine(to: CGPoint(x: 430, y: 260))
arrow.addLine(to: CGPoint(x: 430, y: 240))
arrow.closeSubpath()
context.addPath(arrow)
context.fillPath()

func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
  ]
  (text as NSString).draw(at: point, withAttributes: attributes)
}

drawText("Install PersonaStack", at: CGPoint(x: 36, y: 420), font: .systemFont(ofSize: 23, weight: .semibold), color: .white)
drawText("Drag the app to Applications to install", at: CGPoint(x: 36, y: 394), font: .systemFont(ofSize: 12, weight: .regular), color: NSColor(white: 0.78, alpha: 1))

// Finder uses black filenames over picture backgrounds. Keep both native labels
// readable beneath the 112-point icons positioned by package-macos.sh.
NSColor(red: 0.82, green: 0.86, blue: 0.93, alpha: 1).setFill()
for centerX in [CGFloat(180), CGFloat(560)] {
  NSBezierPath(roundedRect: CGRect(x: centerX - 63, y: 157, width: 126, height: 22), xRadius: 5, yRadius: 5).fill()
}

context.restoreGState()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
  fatalError("Could not encode disk image background")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
