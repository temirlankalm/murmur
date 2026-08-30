import AppKit
import CoreGraphics

// Renders the logo PDF into the assets Murmur needs: a rounded app icon and a
// transparent template image for the menu bar. Run from tools/, not at build time.

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: makeicon <logo.pdf> <outdir>\n", stderr); exit(1) }
let pdfURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let doc = CGPDFDocument(pdfURL as CFURL), let page = doc.page(at: 1) else {
    fputs("could not read the PDF\n", stderr); exit(1)
}
let box = page.getBoxRect(.cropBox)

/// Render the page at a generous size so cropping keeps plenty of detail.
let scale = 2400 / max(box.width, box.height)
let w = Int(box.width * scale), h = Int(box.height * scale)
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
ctx.drawPDFPage(page)
guard let full = ctx.makeImage() else { exit(1) }

// MARK: - Find the drawing

/// The PDF carries its own pale background, so "ink" is anything clearly
/// darker than the corner pixel rather than anything non-transparent.
guard let data = ctx.data else { exit(1) }
let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
func luminance(_ x: Int, _ y: Int) -> Double {
    let i = (y * w + x) * 4
    return 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
}
let background = luminance(2, 2)
/// The page's own background colour, needed when re-drawing the crop: areas the
/// drawing doesn't reach must read as background, not as untouched black.
let backgroundColor = CGColor(
    red: Double(pixels[(2 * w + 2) * 4]) / 255,
    green: Double(pixels[(2 * w + 2) * 4 + 1]) / 255,
    blue: Double(pixels[(2 * w + 2) * 4 + 2]) / 255,
    alpha: 1)
let threshold = background - 30

var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w where luminance(x, y) < threshold {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard minX < maxX else { fputs("found no drawing in the PDF\n", stderr); exit(1) }
let inkRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let ink = full.cropping(to: inkRect) else { exit(1) }
print("drawing found at \(Int(inkRect.width))×\(Int(inkRect.height)) of \(w)×\(h)")

// MARK: - Ink with the background dropped

/// The drawing carries its own pale background. Keeping it would show as a
/// rectangle inside the icon's rounded plate, so turn the paleness into
/// transparency and keep only the strokes.
func inkMask(size: Int, red: Double, green: Double, blue: Double) -> CGImage? {
    guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let side = CGFloat(size)
    c.setFillColor(backgroundColor)
    c.fill(CGRect(x: 0, y: 0, width: side, height: side))

    let ratio = CGFloat(ink.width) / CGFloat(ink.height)
    let drawn = ratio > 1 ? CGSize(width: side, height: side / ratio)
                          : CGSize(width: side * ratio, height: side)
    c.interpolationQuality = .high
    c.draw(ink, in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                           width: drawn.width, height: drawn.height))

    guard let d = c.data else { return nil }
    let p = d.bindMemory(to: UInt8.self, capacity: size * size * 4)
    for i in stride(from: 0, to: size * size * 4, by: 4) {
        let lum = 0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])
        let alpha = max(0, min(1, (background - lum) / (background - 40)))
        // Premultiplied, so the colour is scaled by its own alpha.
        p[i]     = UInt8(red * alpha * 255)
        p[i + 1] = UInt8(green * alpha * 255)
        p[i + 2] = UInt8(blue * alpha * 255)
        p[i + 3] = UInt8(alpha * 255)
    }
    return c.makeImage()
}

// MARK: - App icon

/// macOS shows the icns exactly as given, so the rounded square is ours to draw.
/// Apple's grid leaves the artwork inset rather than bleeding to the edge.
func appIcon(size: Int) -> CGImage? {
    guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let side = CGFloat(size)
    let plate = CGRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88)
    let radius = plate.width * 0.2237  // the macOS squircle, near enough at these sizes

    c.setFillColor(CGColor(red: 0.945, green: 0.945, blue: 0.949, alpha: 1))
    c.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.fillPath()

    let inset = Int(side * 0.68)
    guard let cat = inkMask(size: inset, red: 0.290, green: 0.310, blue: 0.345) else { return nil }
    c.interpolationQuality = .high
    c.draw(cat, in: CGRect(x: (side - CGFloat(inset)) / 2, y: (side - CGFloat(inset)) / 2,
                           width: CGFloat(inset), height: CGFloat(inset)))
    return c.makeImage()
}

// MARK: - Menu bar template

/// Template images are drawn by AppKit using only their alpha, so the colour
/// is thrown away — what matters is that the pale background becomes clear.
func template(size: Int) -> CGImage? {
    // AppKit throws the colour away and uses only the alpha, so black is fine.
    inkMask(size: size, red: 0, green: 0, blue: 0)
}

func write(_ image: CGImage?, to name: String) {
    guard let image,
          let dest = CGImageDestinationCreateWithURL(
            outDir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)
    else { fputs("failed writing \(name)\n", stderr); return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

import ImageIO
import UniformTypeIdentifiers

// The names iconutil expects. Several sizes serve two slots.
let slots: [(size: Int, names: [String])] = [
    (16,   ["icon_16x16.png"]),
    (32,   ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,   ["icon_32x32@2x.png"]),
    (128,  ["icon_128x128.png"]),
    (256,  ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512,  ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]
for slot in slots {
    let image = appIcon(size: slot.size)
    for name in slot.names { write(image, to: name) }
}

// Kept alongside in case the menu bar ever wants the cat instead of a symbol.
write(template(size: 18), to: "menubar.png")
write(template(size: 36), to: "menubar@2x.png")
print("written to \(outDir.path)")
