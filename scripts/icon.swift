import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("packaging/tCode.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = points * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let s = CGFloat(pixels) / 1024
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.19, alpha: 1).setFill()
    let shape = NSBezierPath(
      roundedRect: NSRect(x: 64 * s, y: 64 * s, width: 896 * s, height: 896 * s), xRadius: 192 * s,
      yRadius: 192 * s)
    shape.fill()
    NSColor(calibratedRed: 0.55, green: 0.84, blue: 0.75, alpha: 1).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 58 * s
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: 358 * s, y: 667 * s))
    path.line(to: NSPoint(x: 218 * s, y: 512 * s))
    path.line(to: NSPoint(x: 358 * s, y: 357 * s))
    path.move(to: NSPoint(x: 666 * s, y: 667 * s))
    path.line(to: NSPoint(x: 806 * s, y: 512 * s))
    path.line(to: NSPoint(x: 666 * s, y: 357 * s))
    path.move(to: NSPoint(x: 572 * s, y: 716 * s))
    path.line(to: NSPoint(x: 452 * s, y: 308 * s))
    path.stroke()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let filename = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: iconset.appendingPathComponent(filename))
  }
}
