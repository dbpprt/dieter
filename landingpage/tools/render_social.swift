// Run from the repository root: swift landingpage/tools/render_social.swift
// Regenerates the website's sharing image from its real native screenshots.
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let staticRoot = root.appendingPathComponent("landingpage/static")
let fontURL = staticRoot.appendingPathComponent("fonts/Sora-Variable.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor]
let postScriptName = descriptors?.first.flatMap {
    CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
} ?? "HelveticaNeue-Bold"

let width = 1200, height = 630
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, ink: UInt32) {
    let descriptor = NSFontDescriptor(name: postScriptName, size: size).addingAttributes([
        .variation: [NSNumber(value: 0x77676874): NSNumber(value: size >= 30 ? 650 : 400)]
    ])
    let font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(ink)]
    let string = value as NSString
    let bounds = string.size(withAttributes: attributes)
    string.draw(at: NSPoint(x: x, y: CGFloat(height) - top - bounds.height), withAttributes: attributes)
}
func image(_ path: String, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat) {
    guard let image = NSImage(contentsOf: staticRoot.appendingPathComponent(path)) else {
        fatalError("Missing source image: \(path)")
    }
    let rect = NSRect(x: x, y: 630 - top - height, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

color(0xfafaf7).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
color(0xe6eadd).setFill()
NSBezierPath(roundedRect: NSRect(x: 640, y: 58, width: 520, height: 416), xRadius: 20, yRadius: 20).fill()
image("brand/mark-mono-dark.svg", x: 64, top: 58, width: 34, height: 34, radius: 0)
text("Dieter", x: 112, top: 53, size: 30, ink: 0x1b211b)
text("Your agents.", x: 60, top: 155, size: 63, ink: 0x1b211b)
text("Your machines.", x: 60, top: 239, size: 63, ink: 0x1b211b)
text("One workspace.", x: 60, top: 323, size: 63, ink: 0x5f724b)
text("Native apps. Local execution. Open source.", x: 64, top: 452, size: 20, ink: 0x566052)
text("getdieter.com", x: 64, top: 553, size: 17, ink: 0x566052)
image("images/screenshots/macos-workspace.png", x: 664, top: 231, width: 472, height: 298, radius: 8)
image("images/screenshots/android-activity.png", x: 994, top: 78, width: 144, height: 323, radius: 15)

NSGraphicsContext.restoreGraphicsState()
let destination = staticRoot.appendingPathComponent("images/og-image.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
print("Rendered \(destination.lastPathComponent): \(width) × \(height)")
