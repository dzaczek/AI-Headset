import AppKit

// Ikona rysowana wektorowo. Swiadomie NIE uzywamy SF Symbols: licencja
// Apple zabrania ich w ikonach aplikacji i logotypach, a repo jest
// publiczne. Ksztalt: sluchawki nauszne z mikrofonem na palaku.

func drawIcon(size S: CGFloat, into ctx: CGContext) {
    let u = S / 1024.0          // wszystko liczone w siatce 1024

    // --- tlo: macOS "squircle" wpisany w plotno wg siatki Apple ---
    let inset = 100 * u
    let side  = 824 * u
    let bg    = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = 185 * u

    let path = CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        NSColor(srgbRed: 0.36, green: 0.24, blue: 0.78, alpha: 1).cgColor,  // indygo
        NSColor(srgbRed: 0.60, green: 0.28, blue: 0.85, alpha: 1).cgColor,  // fiolet
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: bg.minX, y: bg.maxY),
                               end:   CGPoint(x: bg.maxX, y: bg.minY),
                               options: [])
    }
    ctx.restoreGState()

    // --- sluchawki, biale, grube kreski zeby przetrwac 16 px ---
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)

    let cx: CGFloat = 512 * u
    let bandY: CGFloat = 545 * u
    let R: CGFloat = 225 * u

    // palak
    ctx.setLineWidth(74 * u)
    ctx.addArc(center: CGPoint(x: cx, y: bandY), radius: R,
               startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()

    // nauszniki
    let cupW: CGFloat = 165 * u
    let cupH: CGFloat = 235 * u
    for sign in [-1.0, 1.0] as [CGFloat] {
        let rect = CGRect(x: cx + sign * R - cupW / 2,
                          y: bandY - cupH + 45 * u,
                          width: cupW, height: cupH)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 78 * u, cornerHeight: 78 * u, transform: nil))
        ctx.fillPath()
    }

    // palak mikrofonu -- to on odroznia "headset" od zwyklych sluchawek
    ctx.setLineWidth(46 * u)
    ctx.move(to: CGPoint(x: cx - R, y: bandY - cupH + 60 * u))
    ctx.addQuadCurve(to: CGPoint(x: cx + 30 * u, y: bandY - 260 * u),
                     control: CGPoint(x: cx - R + 20 * u, y: bandY - 300 * u))
    ctx.strokePath()

    // kapsula mikrofonu
    ctx.fillEllipse(in: CGRect(x: cx + 10 * u, y: bandY - 300 * u, width: 92 * u, height: 92 * u))
}

func render(size: Int) -> Data? {
    let S = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    drawIcon(size: S, into: ctx)
    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// Komplet wymagany przez iconutil.
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    guard let data = render(size: px) else {
        FileHandle.standardError.write("nie udalo sie wyrenderowac \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wyrenderowano \(sizes.count) rozmiarow do \(outDir)")
