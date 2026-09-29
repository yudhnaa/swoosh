#!/usr/bin/env swift
import Cocoa

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

// Draw background
let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 224, yRadius: 224)
NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.1, alpha: 1.0).setFill()
bgPath.fill()

// Draw swoosh
let swooshPath = NSBezierPath()
swooshPath.move(to: NSPoint(x: 200, y: 300))
swooshPath.curve(to: NSPoint(x: 824, y: 700), controlPoint1: NSPoint(x: 400, y: 100), controlPoint2: NSPoint(x: 600, y: 900))
swooshPath.lineWidth = 100
swooshPath.lineCapStyle = .round
NSColor.white.setStroke()
swooshPath.stroke()

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed to generate image data")
    exit(1)
}

let url = URL(fileURLWithPath: "icon_1024x1024.png")
try? pngData.write(to: url)
print("Generated icon_1024x1024.png")
