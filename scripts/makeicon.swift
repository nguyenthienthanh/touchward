import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon at every size macOS asks for, then leaves an .iconset directory
// for `iconutil`. Drawing it in code rather than shipping a PNG means the icon can be
// regenerated at any size, and there is no binary asset to keep in sync with the design.
//
// Style follows the house rules: flat, generous whitespace, one accent used sparingly.
// No gradients, no glow.

struct Palette {
    // Deep teal reads as an instrument, not a toy, and holds up against both the light
    // and dark Dock backgrounds.
    static let background = CGColor(red: 0.055, green: 0.400, blue: 0.373, alpha: 1)
    static let glass = CGColor(red: 0.976, green: 0.988, blue: 0.988, alpha: 1)
    static let glassEdge = CGColor(red: 0.055, green: 0.400, blue: 0.373, alpha: 0.18)
    static let touch = CGColor(red: 0.043, green: 0.286, blue: 0.267, alpha: 1)
    static let ripple = CGColor(red: 0.043, green: 0.286, blue: 0.267, alpha: 0.30)
}

/// The Big Sur icon grid: art sits inside ~80% of the canvas so it lines up with Apple's
/// own icons in the Dock.
func draw(size: CGFloat, into context: CGContext) {
    let inset = size * 0.10
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = plate.width * 0.2237  // Apple's continuous-corner ratio

    context.setFillColor(Palette.background)
    context.addPath(CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.fillPath()

    // Below 64px there are not enough pixels for a finger and a ripple — they collapse
    // into a dark smudge. Small sizes keep only the silhouette that identifies the app:
    // a screen with a contact point on it, both scaled up to stay legible.
    let isSmall = size < 64

    // The screen: a landscape panel, matching the 16:9 portable monitor this drives.
    let screenWidth = plate.width * (isSmall ? 0.86 : 0.66)
    let screenHeight = screenWidth * 0.5625
    let screen = CGRect(
        x: plate.midX - screenWidth / 2,
        y: plate.midY - screenHeight / 2,
        width: screenWidth,
        height: screenHeight
    )
    let screenCorner = max(size * 0.02, 1)

    context.setFillColor(Palette.glass)
    context.addPath(CGPath(roundedRect: screen, cornerWidth: screenCorner, cornerHeight: screenCorner, transform: nil))
    context.fillPath()

    context.setStrokeColor(Palette.glassEdge)
    context.setLineWidth(max(size * 0.006, 0.5))
    context.addPath(CGPath(roundedRect: screen, cornerWidth: screenCorner, cornerHeight: screenCorner, transform: nil))
    context.strokePath()

    // Touch point in the upper-left quadrant. A dot near the middle of a lit rectangle,
    // ringed by concentric circles, reads as a camera lens — the finger below and the
    // off-centre placement are what make it read as a touch instead.
    let point = isSmall
        ? CGPoint(x: screen.midX, y: screen.midY)
        : CGPoint(x: screen.minX + screen.width * 0.36, y: screen.minY + screen.height * 0.64)
    let dotRadius = screen.height * (isSmall ? 0.30 : 0.115)

    // One ring, not two: a single ripple says "contact", a stack of them says "lens".
    if !isSmall {
        let radius = dotRadius * 2.0
        context.setStrokeColor(Palette.ripple)
        context.setLineWidth(max(size * 0.009, 0.5))
        context.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                      width: radius * 2, height: radius * 2))
        context.strokePath()
    }

    // A finger reaching in from the lower right. Two things stop it reading as a stylus:
    // it is thick relative to its length, and it runs off the edge of the screen instead
    // of floating inside it — a hand enters the frame, a pen sits in it.
    if !isSmall {
        let fingerWidth = screen.height * 0.42
        let reach = screen.width * 1.2  // deliberately overshoots; the clip trims it
        let angle = -CGFloat.pi / 4     // down and to the right, away from the contact
        let gap = dotRadius * 1.35

        context.saveGState()
        // Clipping to the screen is what makes the finger look like it comes from
        // outside the picture rather than being an object drawn on the glass.
        context.addPath(CGPath(roundedRect: screen, cornerWidth: screenCorner,
                               cornerHeight: screenCorner, transform: nil))
        context.clip()

        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)

        let finger = CGRect(x: gap, y: -fingerWidth / 2, width: reach, height: fingerWidth)
        context.setFillColor(Palette.touch)
        context.addPath(CGPath(roundedRect: finger,
                               cornerWidth: fingerWidth / 2, cornerHeight: fingerWidth / 2,
                               transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    context.setFillColor(Palette.touch)
    context.addEllipse(in: CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                  width: dotRadius * 2, height: dotRadius * 2))
    context.fillPath()
}

func render(size: Int, to url: URL) -> Bool {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    draw(size: dimension, into: context)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }

    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// MARK: entry

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "dist/AppIcon.iconset")

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// Exactly the set `iconutil` expects; anything missing makes it refuse the whole bundle.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

var failures = 0
for variant in variants {
    let url = outputDirectory.appendingPathComponent("\(variant.name).png")
    if render(size: variant.pixels, to: url) {
        print("  \(variant.name).png (\(variant.pixels)px)")
    } else {
        FileHandle.standardError.write("  ✗ \(variant.name) failed\n".data(using: .utf8)!)
        failures += 1
    }
}

if failures > 0 { exit(1) }
print("✓ \(variants.count) images → \(outputDirectory.path)")
