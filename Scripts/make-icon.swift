import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.76, blue: 0.63, alpha: 1), ending: NSColor(srgbRed: 0.04, green: 0.38, blue: 0.37, alpha: 1))!.draw(in: shape, angle: -75)
        for (x, y) in [(CGFloat(320), CGFloat(420)), (512, 640), (704, 500)] {
            let track = NSBezierPath(roundedRect: NSRect(x: x - 15, y: 265, width: 30, height: 494), xRadius: 15, yRadius: 15)
            NSColor.white.withAlphaComponent(0.4).setFill(); track.fill()
            let knob = NSBezierPath(roundedRect: NSRect(x: x - 66, y: y - 32, width: 132, height: 64), xRadius: 24, yRadius: 24)
            NSColor.white.setFill(); knob.fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
