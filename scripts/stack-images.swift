import AppKit
let args = Array(CommandLine.arguments.dropFirst())
let out = args.last!
let imgs = args.dropLast().compactMap { NSImage(contentsOfFile: $0)?.representations.first as? NSBitmapImageRep }
let w = imgs.map { $0.pixelsWide }.max()!, gap = 10
let h = imgs.reduce(0) { $0 + $1.pixelsHigh + gap }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
var y = h
for i in imgs { y -= i.pixelsHigh; i.draw(in: NSRect(x: 0, y: y, width: i.pixelsWide, height: i.pixelsHigh)); y -= gap }
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
