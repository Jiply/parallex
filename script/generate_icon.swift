import AppKit
import Foundation

private struct IconVariant {
  let type: String
  let pixels: Int
}

@main
private struct GenerateParallexIcon {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw NSError(
        domain: "ParallexIconGenerator",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "usage: generate-icon OUTPUT.icns"]
      )
    }

    let variants = [
      IconVariant(type: "icp4", pixels: 16),
      IconVariant(type: "ic11", pixels: 32),
      IconVariant(type: "icp5", pixels: 32),
      IconVariant(type: "ic12", pixels: 64),
      IconVariant(type: "ic07", pixels: 128),
      IconVariant(type: "ic13", pixels: 256),
      IconVariant(type: "ic08", pixels: 256),
      IconVariant(type: "ic14", pixels: 512),
      IconVariant(type: "ic09", pixels: 512),
      IconVariant(type: "ic10", pixels: 1024),
    ]

    var body = Data()
    for variant in variants {
      let png = try renderPNG(pixels: variant.pixels)
      body.append(contentsOf: variant.type.utf8)
      appendBigEndianLength(8 + png.count, to: &body)
      body.append(png)
    }

    var icon = Data("icns".utf8)
    appendBigEndianLength(8 + body.count, to: &icon)
    icon.append(body)

    let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try icon.write(to: outputURL, options: .atomic)
  }

  private static func renderPNG(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels,
      pixelsHigh: pixels,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      throw NSError(
        domain: "ParallexIconGenerator",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "could not allocate icon bitmap"]
      )
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    ParallexIcon.appIconImage.draw(
      in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
      from: .zero,
      operation: .copy,
      fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw NSError(
        domain: "ParallexIconGenerator",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "could not encode icon bitmap"]
      )
    }
    return png
  }

  private static func appendBigEndianLength(_ length: Int, to data: inout Data) {
    var value = UInt32(length).bigEndian
    withUnsafeBytes(of: &value) { bytes in
      data.append(contentsOf: bytes)
    }
  }
}
