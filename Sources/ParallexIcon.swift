import AppKit

enum ParallexIcon {
  static let statusItemImage = makeTemplateImage(
    size: NSSize(width: 18, height: 18),
    horizontalInset: 0.5,
    strokeWidth: 1.35
  )

  static let menuItemImage = makeTemplateImage(
    size: NSSize(width: 16, height: 16),
    horizontalInset: 4 / 9,
    strokeWidth: 1.2
  )

  static let appIconImage = NSImage(
    size: NSSize(width: 1024, height: 1024),
    flipped: false
  ) { bounds in
    NSGraphicsContext.current?.imageInterpolation = .high

    let tileRect = bounds.insetBy(dx: 64, dy: 64)
    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: 210, yRadius: 210)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 42
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowOffset = NSSize(width: 0, height: -14)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.965, green: 0.965, blue: 0.95, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.08).setStroke()
    tilePath.lineWidth = 6
    tilePath.stroke()

    let markRect = bounds.insetBy(dx: 180, dy: 180)
    drawStackedHexagons(
      in: markRect,
      strokeWidth: 54,
      rearColor: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.075, alpha: 0.55),
      frontColor: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.075, alpha: 1),
      occlusionColor: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.95, alpha: 1)
    )
    return true
  }

  private static func makeTemplateImage(
    size: NSSize,
    horizontalInset: CGFloat,
    strokeWidth: CGFloat
  ) -> NSImage {
    let image = NSImage(size: size, flipped: false) { bounds in
      NSGraphicsContext.current?.shouldAntialias = true
      drawStackedHexagons(
        in: bounds.insetBy(dx: horizontalInset, dy: 0),
        strokeWidth: strokeWidth,
        rearColor: .black.withAlphaComponent(0.55),
        frontColor: .black,
        occlusionColor: nil
      )
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func drawStackedHexagons(
    in bounds: NSRect,
    strokeWidth: CGFloat,
    rearColor: NSColor,
    frontColor: NSColor,
    occlusionColor: NSColor?
  ) {
    let horizontalOffsetRatio: CGFloat = 0.24
    let verticalOffsetRatio: CGFloat = 0.20
    let rotationDegrees: CGFloat = -16
    let rotationRadians = abs(rotationDegrees) * .pi / 180
    let drawingBounds = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
    let hexagonHeightRatio = sqrt(3) / 2
    let stackedHeightRatio = hexagonHeightRatio + verticalOffsetRatio
    let rotatedWidthRatio = (1 + horizontalOffsetRatio) * cos(rotationRadians)
      + stackedHeightRatio * sin(rotationRadians)
    let rotatedHeightRatio = (1 + horizontalOffsetRatio) * sin(rotationRadians)
      + stackedHeightRatio * cos(rotationRadians)
    let hexagonWidth = min(
      drawingBounds.width / rotatedWidthRatio,
      drawingBounds.height / rotatedHeightRatio
    )
    let hexagonHeight = hexagonWidth * sqrt(3) / 2
    let horizontalOffset = hexagonWidth * horizontalOffsetRatio
    let verticalOffset = hexagonWidth * verticalOffsetRatio
    let rearRect = NSRect(
      x: drawingBounds.midX - hexagonWidth / 2 - horizontalOffset / 2,
      y: drawingBounds.midY - hexagonHeight / 2 + verticalOffset / 2,
      width: hexagonWidth,
      height: hexagonHeight
    )
    let frontRect = rearRect.offsetBy(dx: horizontalOffset, dy: -verticalOffset)

    NSGraphicsContext.saveGraphicsState()
    let rotation = NSAffineTransform()
    rotation.translateX(by: drawingBounds.midX, yBy: drawingBounds.midY)
    rotation.rotate(byDegrees: rotationDegrees)
    rotation.translateX(by: -drawingBounds.midX, yBy: -drawingBounds.midY)
    rotation.concat()

    let rearPath = hexagonPath(in: rearRect)
    rearColor.setStroke()
    rearPath.lineWidth = strokeWidth
    rearPath.lineJoinStyle = .round
    rearPath.lineCapStyle = .round
    rearPath.stroke()

    let frontPath = hexagonPath(in: frontRect)
    if let occlusionColor {
      occlusionColor.setFill()
      frontPath.fill()
    } else {
      NSGraphicsContext.current?.compositingOperation = .clear
      frontPath.fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    frontColor.setStroke()
    frontPath.lineWidth = strokeWidth
    frontPath.lineJoinStyle = .round
    frontPath.lineCapStyle = .round
    frontPath.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }

  private static func hexagonPath(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.75, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.75, y: rect.minY))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.minY))
    path.line(to: NSPoint(x: rect.minX, y: rect.midY))
    path.close()
    return path
  }
}
