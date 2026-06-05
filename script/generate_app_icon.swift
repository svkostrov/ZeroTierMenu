import AppKit
import Foundation

let outputRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconsetURL = outputRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let symbolName = "point.3.connected.trianglepath.dotted"

let iconVariants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (size, filename) in iconVariants {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = CGFloat(size) * 0.225
    let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1.0),
        NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.28, alpha: 1.0),
        NSColor(calibratedRed: 0.09, green: 0.40, blue: 0.86, alpha: 1.0)
    ])!
    gradient.draw(in: backgroundPath, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    backgroundPath.addClip()
    let highlightRect = NSRect(x: CGFloat(size) * 0.10, y: CGFloat(size) * 0.58, width: CGFloat(size) * 0.80, height: CGFloat(size) * 0.26)
    let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: CGFloat(size) * 0.12, yRadius: CGFloat(size) * 0.12)
    NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
    highlightPath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.46, weight: .regular)
        let symbolImage = symbol.withSymbolConfiguration(config) ?? symbol
        let symbolRect = NSRect(
            x: CGFloat(size) * 0.19,
            y: CGFloat(size) * 0.19,
            width: CGFloat(size) * 0.62,
            height: CGFloat(size) * 0.62
        )

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.28)
        shadow.shadowBlurRadius = CGFloat(size) * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(size) * 0.01)
        shadow.set()
        NSColor.white.set()
        symbolImage.draw(in: symbolRect)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to create PNG for \(filename)")
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(filename))
}
