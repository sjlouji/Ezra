// Draws one variant of the app icon as a 1024-pixel PNG.
// Usage: swift Tools/make-icon.swift <light|dark> <day|night> <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4, ["light", "dark"].contains(CommandLine.arguments[1]),
      ["day", "night"].contains(CommandLine.arguments[2])
else { fatalError("usage: swift Tools/make-icon.swift <light|dark> <day|night> <output.png>") }
let dark = CommandLine.arguments[1] == "dark"
let night = CommandLine.arguments[2] == "night"

/// The colours of one variant, top to bottom where a list is given.
struct Look {
    var tile: [UInt32], tileShadow: UInt32, sky: [UInt32], glow: UInt32
    var far: [UInt32], middle: [UInt32], near: [UInt32], rim: CGFloat
}
let look: Look = switch (dark, night) {
case (false, false): Look(tile: [0xFFFFFF, 0xEEF6FF, 0xBFDCFA], tileShadow: 0x1B3A6B, sky: [0x1877F2, 0x3FA2F7, 0x8FD6FB], glow: 0xFFE9A8,
                          far: [0x7CC4FA, 0x4C9BF2], middle: [0x3F8BEF, 0x1E63DC], near: [0x1B5BD6, 0x1241B0], rim: 0.45)
case (false, true): Look(tile: [0xFFFFFF, 0xF4EEFF, 0xD9CCF8], tileShadow: 0x4A3A8B, sky: [0x3346D3, 0x6F6BE6, 0xC7A2F0, 0xF6BBD6], glow: 0xFFFFFF,
                         far: [0xB89AF0, 0x7F7BEA], middle: [0x6E78E8, 0x4458D6], near: [0x4660DC, 0x2C3FB4], rim: 0.45)
case (true, false): Look(tile: [0x394468, 0x262F4E, 0x171D36], tileShadow: 0x000000, sky: [0x0F6BF5, 0x2F9DFB, 0x7FE0FF], glow: 0xFFE9A8,
                         far: [0x62C4FF, 0x2F8FF5], middle: [0x2A7DF2, 0x1450D8], near: [0x1248D2, 0x0A2E9C], rim: 0.25)
case (true, true): Look(tile: [0x333A63, 0x222748, 0x14172F], tileShadow: 0x000000, sky: [0x12155A, 0x2A2494, 0x5A3BC4, 0x9A62E0], glow: 0xE9DDFF,
                        far: [0x7F58DC, 0x5238BE], middle: [0x4A34B8, 0x30228E], near: [0x2C2190, 0x191458], rim: 0.25)
}

let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Work with the origin at the top-left.
context.translateBy(x: 0, y: CGFloat(side))
context.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
    )!
}

func fill(_ path: CGPath, from start: CGPoint, to end: CGPoint, _ colors: [UInt32]) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors.map { color($0) } as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// The tile: the standard macOS rounded square, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(look.tileShadow, dark ? 0.5 : 0.3))
context.addPath(tilePath)
context.setFillColor(color(look.tile[1]))
context.fillPath()
context.restoreGState()
fill(tilePath, from: CGPoint(x: 512, y: tile.minY), to: CGPoint(x: 512, y: tile.maxY), look.tile)
// A hairline of light along the tile's edge, as on glass.
context.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
context.setStrokeColor(color(0xFFFFFF, dark ? 0.12 : 0.8))
context.setLineWidth(4)
context.strokePath()

// The disc: the sky.
let disc = CGRect(x: 512 - 300, y: 512 - 300, width: 600, height: 600)
let discPath = CGPath(ellipseIn: disc, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(look.near[1], dark ? 0.6 : 0.38))
context.addPath(discPath)
context.setFillColor(color(look.sky[1]))
context.fillPath()
context.restoreGState()
fill(discPath, from: CGPoint(x: 512, y: disc.minY), to: CGPoint(x: 512, y: 600), look.sky)

context.saveGState()
context.addPath(discPath)
context.clip()

/// A soft halo: rings of the glow colour fading outwards.
func halo(around rect: CGRect, reach: CGFloat, strength: CGFloat) {
    for step in stride(from: 16, through: 1, by: -1) {
        context.setFillColor(color(look.glow, strength / 16))
        let spread = reach * CGFloat(step) / 16
        context.fillEllipse(in: rect.insetBy(dx: -spread, dy: -spread))
    }
}

if night {
    // A crescent moon: a disc with an offset disc cut out of it.
    let moon = CGRect(x: 612, y: 300, width: 118, height: 118)
    halo(around: moon, reach: dark ? 70 : 40, strength: dark ? 0.22 : 0.14)
    context.saveGState()
    context.addEllipse(in: moon)
    context.clip()
    context.addRect(CGRect(x: 0, y: 0, width: side, height: side))
    context.addEllipse(in: moon.offsetBy(dx: 36, dy: -22))
    context.clip(using: .evenOdd)
    context.setFillColor(color(dark ? 0xF1E8FF : 0xFFFDF4))
    context.fill(moon)
    context.restoreGState()
    // A few stars: one four-pointed, the rest dots.
    let sparkle = CGMutablePath()
    let (sx, sy, long, short): (CGFloat, CGFloat, CGFloat, CGFloat) = (396, 326, 15, 4)
    sparkle.move(to: CGPoint(x: sx, y: sy - long))
    for (dx, dy) in [(short, -short), (long, 0), (short, short), (0, long), (-short, short), (-long, 0), (-short, -short)] as [(CGFloat, CGFloat)] {
        sparkle.addLine(to: CGPoint(x: sx + dx, y: sy + dy))
    }
    sparkle.closeSubpath()
    context.addPath(sparkle)
    context.setFillColor(color(0xFFFFFF, 0.95))
    context.fillPath()
    for (x, y, size, alpha) in [(470, 388, 7, 0.8), (332, 418, 5, 0.6), (748, 440, 6, 0.7), (560, 286, 4, 0.55)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        context.setFillColor(color(0xFFFFFF, alpha))
        context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
    }
} else {
    // A golden sun.
    let sun = CGRect(x: 618, y: 318, width: 124, height: 124)
    halo(around: sun, reach: 46, strength: 0.3)
    context.saveGState()
    context.addEllipse(in: sun)
    context.clip()
    let gold = CGGradient(colorsSpace: space, colors: [color(0xFFF3B0), color(0xFFD95E)] as CFArray, locations: nil)!
    context.drawLinearGradient(gold, start: CGPoint(x: sun.minX, y: sun.minY), end: CGPoint(x: sun.maxX, y: sun.maxY), options: [])
    context.restoreGState()
}

/// A band of hills from the left edge to the right, filled down to the bottom of the disc.
func hills(_ points: [(x: CGFloat, y: CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: points[0].x, y: points[0].y))
    for index in 1..<points.count {
        let (from, to) = (points[index - 1], points[index])
        let reach = (to.x - from.x) * 0.5
        path.addCurve(
            to: CGPoint(x: to.x, y: to.y),
            control1: CGPoint(x: from.x + reach, y: from.y), control2: CGPoint(x: to.x - reach, y: to.y)
        )
    }
    path.addLine(to: CGPoint(x: disc.maxX + 20, y: disc.maxY + 20))
    path.addLine(to: CGPoint(x: disc.minX - 20, y: disc.maxY + 20))
    path.closeSubpath()
    return path
}

// A band of light on the horizon, then three ranges, nearest darkest.
let horizon = CGRect(x: disc.minX, y: 520, width: disc.width, height: 90)
context.saveGState()
context.clip(to: horizon)
let mist = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0), color(0xFFFFFF, dark ? 0.16 : 0.34)] as CFArray, locations: nil)!
context.drawLinearGradient(mist, start: CGPoint(x: 512, y: horizon.minY), end: CGPoint(x: 512, y: horizon.maxY), options: [])
context.restoreGState()
fill(hills([(190, 600), (330, 548), (500, 606), (690, 540), (840, 590)]), from: CGPoint(x: 512, y: 540), to: CGPoint(x: 512, y: 720), look.far)
fill(hills([(190, 668), (370, 702), (560, 632), (740, 668), (840, 640)]), from: CGPoint(x: 512, y: 630), to: CGPoint(x: 512, y: 800), look.middle)
fill(hills([(190, 780), (360, 728), (540, 768), (720, 716), (840, 752)]), from: CGPoint(x: 512, y: 716), to: CGPoint(x: 512, y: 830), look.near)
context.restoreGState()

// A hairline of light around the disc's rim.
context.addPath(discPath)
context.setStrokeColor(color(0xFFFFFF, look.rim))
context.setLineWidth(3)
context.strokePath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: CommandLine.arguments[3]) as CFURL, UTType.png.identifier as CFString, 1, nil
      )
else { fatalError("could not create the image") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write the PNG") }
