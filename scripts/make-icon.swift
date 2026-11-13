// Renders design/AppIcon.svg into every Mac icon size in the asset catalog.
// Usage: swift scripts/make-icon.swift   (uses macOS's built-in SVG support, no extra tools)
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svg = root.appendingPathComponent("design/AppIcon.svg")
let out = root.appendingPathComponent("JuiceTracker/Assets.xcassets/AppIcon.appiconset")
guard let image = NSImage(contentsOf: svg) else { fatalError("Couldn't read \(svg.path)") }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        print("wrote \(name) (\(px)px)")
    }
}
