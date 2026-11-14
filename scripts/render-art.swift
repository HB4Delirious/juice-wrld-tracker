// Renders the SVG artwork in design/ to the PNGs the app and DMG use, with macOS's built-in SVG support.
// Usage: swift scripts/render-art.swift
//   design/AppIcon.svg       -> every Mac icon size in JuiceTracker/Assets.xcassets/AppIcon.appiconset
//   design/dmg-background.svg -> design/dmg-background.png and @2x (the DMG window background)
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func render(_ svgPath: String, width: Int, height: Int, to outPath: String) {
    let svg = root.appendingPathComponent(svgPath)
    guard let image = NSImage(contentsOf: svg) else { fatalError("Couldn't read \(svg.path)") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(outPath))
    print("wrote \(outPath) (\(width)x\(height))")
}

let iconDir = "JuiceTracker/Assets.xcassets/AppIcon.appiconset"
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        render("design/AppIcon.svg", width: points * scale, height: points * scale,
               to: "\(iconDir)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
    }
}
render("design/dmg-background.svg", width: 660, height: 420, to: "design/dmg-background.png")
render("design/dmg-background.svg", width: 1320, height: 840, to: "design/dmg-background@2x.png")

// The classic page's doodles for the SwiftUI interface (design/native, from scripts/extract-native-art.py),
// as 1x and 2x images in the asset catalog: name -> size in points.
let native: [(String, Int, Int)] = [
    ("planet", 210, 210), ("heart", 46, 46), ("flash", 560, 560), ("sparkles", 520, 520), ("fly", 32, 32),
    ("scribble", 200, 40), ("squiggle", 140, 12), ("check", 14, 14), ("logo", 64, 64),
    ("sticker1", 30, 30), ("sticker2", 30, 30), ("sticker3", 30, 30), ("sticker4", 30, 30), ("sticker5", 30, 30), ("sticker6", 30, 30),
]
for (name, w, h) in native {
    let dir = "JuiceTracker/Assets.xcassets/jt-\(name).imageset"
    try! FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    render("design/native/\(name).svg", width: w, height: h, to: "\(dir)/\(name).png")
    render("design/native/\(name).svg", width: w * 2, height: h * 2, to: "\(dir)/\(name)@2x.png")
    let contents = """
    {"images":[{"filename":"\(name).png","idiom":"universal","scale":"1x"},{"filename":"\(name)@2x.png","idiom":"universal","scale":"2x"}],\
    "info":{"author":"xcode","version":1}}
    """
    try! contents.write(to: root.appendingPathComponent("\(dir)/Contents.json"), atomically: true, encoding: .utf8)
}
