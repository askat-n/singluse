// Рисует значок приложения: swift Scripts/make-icon.swift <выход.png>
import AppKit

let size = 1024.0
let output = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// Стандартная сетка значков macOS: 824 из 1024 с полями под тень.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
context.addPath(shape)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
let colors = [
    NSColor(red: 0.04, green: 0.05, blue: 0.16, alpha: 1).cgColor,
    NSColor(red: 0.13, green: 0.09, blue: 0.36, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

// Шесть цветных лент, сходящихся в одну точку: шесть модулей в одном приложении.
let ribbons: [(NSColor, CGFloat)] = [
    (NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1), 0),
    (NSColor(red: 0.13, green: 0.85, blue: 0.77, alpha: 1), 60),
    (NSColor(red: 0.98, green: 0.34, blue: 0.50, alpha: 1), 120),
    (NSColor(red: 0.25, green: 0.56, blue: 0.99, alpha: 1), 180),
    (NSColor(red: 0.99, green: 0.68, blue: 0.20, alpha: 1), 240),
    (NSColor(red: 0.45, green: 0.95, blue: 0.70, alpha: 1), 300),
]
context.translateBy(x: size / 2, y: size / 2)
context.setBlendMode(.screen)
for (color, angle) in ribbons {
    context.saveGState()
    context.rotate(by: angle * .pi / 180)
    let petal = CGMutablePath()
    petal.move(to: .zero)
    petal.addCurve(to: CGPoint(x: 0, y: 330), control1: CGPoint(x: 190, y: 90), control2: CGPoint(x: 150, y: 270))
    petal.addCurve(to: .zero, control1: CGPoint(x: -60, y: 240), control2: CGPoint(x: -70, y: 100))
    context.addPath(petal)
    context.setFillColor(color.withAlphaComponent(0.92).cgColor)
    context.fillPath()
    context.restoreGState()
}
context.setBlendMode(.normal)
context.setFillColor(NSColor.white.cgColor)
context.fillEllipse(in: CGRect(x: -38, y: -38, width: 76, height: 76))
context.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
