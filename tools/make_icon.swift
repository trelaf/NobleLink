// Turn square icon artwork into a macOS app icon that macOS 26+ shows full size.
//
// macOS 26 puts any icon that isn't Apple's rounded-square ("squircle") shape on the
// standard 1024-pt grid into a grey backing at reduced size. This masks the artwork to that
// shape: an 824×824 body centred on a 1024×1024 canvas, transparent outside, and writes
// an .iconset with every size, ready for `iconutil -c icns`.
//
// Usage: swift tools/make_icon.swift MASTER.png OUT.iconset [zoom]
//   zoom > 1 enlarges the artwork inside the shape (crops its edges); default 1.0.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let master = NSImage(contentsOfFile: args[1]) else {
    print("usage: make_icon MASTER.png OUT.iconset [zoom]")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
let zoom = args.count > 3 ? CGFloat(Double(args[3]) ?? 1) : 1

/// Apple's icon outline is close to a superellipse |x|^n + |y|^n = 1 with n ≈ 5.
func squircle(in rect: CGRect, exponent n: CGFloat = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    ctx.addPath(squircle(in: body))
    ctx.clip()
    // Fill the shape with the artwork; a little overscan hides the artwork's own rounded corners.
    let art = body.insetBy(dx: -body.width * (zoom - 1) / 2, dy: -body.height * (zoom - 1) / 2)
    var r = CGRect(origin: .zero, size: master.size)
    let cg = master.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    ctx.draw(cg, in: art)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(pixels: base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(pixels: base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(outDir.path)")
