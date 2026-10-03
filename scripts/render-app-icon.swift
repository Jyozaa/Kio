import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "apps/mac/KioMac/Assets.xcassets/AppIcon.appiconset/KioIcon.png")
let size = 1_024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.098, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 210, yRadius: 210).fill()

NSColor.black.setFill()
NSBezierPath(roundedRect: NSRect(x: 176, y: 638, width: 672, height: 180), xRadius: 90, yRadius: 90).fill()

let ribbon = NSBezierPath()
ribbon.move(to: NSPoint(x: 288, y: 385))
ribbon.curve(to: NSPoint(x: 754, y: 442), controlPoint1: NSPoint(x: 416, y: 534), controlPoint2: NSPoint(x: 670, y: 538))
ribbon.curve(to: NSPoint(x: 682, y: 311), controlPoint1: NSPoint(x: 846, y: 361), controlPoint2: NSPoint(x: 812, y: 294))
ribbon.line(to: NSPoint(x: 590, y: 171))
ribbon.line(to: NSPoint(x: 514, y: 276))
ribbon.curve(to: NSPoint(x: 286, y: 314), controlPoint1: NSPoint(x: 427, y: 220), controlPoint2: NSPoint(x: 326, y: 250))
ribbon.curve(to: NSPoint(x: 288, y: 385), controlPoint1: NSPoint(x: 246, y: 275), controlPoint2: NSPoint(x: 236, y: 351))
ribbon.close()
NSColor(calibratedRed: 0.94, green: 0.90, blue: 0.82, alpha: 1).setFill()
ribbon.fill()

NSColor.black.setFill()
for x in [414.0, 535.0] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 353, width: 38, height: 83), xRadius: 19, yRadius: 19).fill()
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the replaceable Kio icon placeholder.")
}
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: destination, options: .atomic)
print("Wrote \(destination.path)")
