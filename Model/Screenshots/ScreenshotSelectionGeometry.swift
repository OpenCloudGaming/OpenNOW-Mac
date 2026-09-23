import CoreGraphics

enum ScreenshotSelectionHandle: CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing, top, leading, trailing, bottom

    var isLeading: Bool { self == .topLeading || self == .leading || self == .bottomLeading }
    var isTrailing: Bool { self == .topTrailing || self == .trailing || self == .bottomTrailing }
    var isTop: Bool { self == .topLeading || self == .top || self == .topTrailing }
    var isBottom: Bool { self == .bottomLeading || self == .bottom || self == .bottomTrailing }

    func position(in rectangle: CGRect) -> CGPoint {
        let x = isLeading ? rectangle.minX : isTrailing ? rectangle.maxX : rectangle.midX
        let y = isTop ? rectangle.minY : isBottom ? rectangle.maxY : rectangle.midY
        return CGPoint(x: x, y: y)
    }
}

enum ScreenshotSelectionGeometry {
    static func imageFrame(in container: CGSize, imageSize: CGSize) -> CGRect {
        guard isValid(container), isValid(imageSize) else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - fittedSize.width) / 2,
            y: (container.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func selection(from start: CGPoint, to end: CGPoint, imageFrame: CGRect, imageSize: CGSize) -> CGRect? {
        guard imageFrame.contains(start), isValid(imageFrame.size), isValid(imageSize),
              end.x.isFinite, end.y.isFinite else { return nil }
        let first = pixelPoint(start, imageFrame: imageFrame, imageSize: imageSize)
        let last = pixelPoint(end, imageFrame: imageFrame, imageSize: imageSize)
        return bounded(
            CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                   width: abs(last.x - first.x), height: abs(last.y - first.y)),
            imageSize: imageSize
        )
    }

    static func bounded(_ rectangle: CGRect, imageSize: CGSize) -> CGRect? {
        guard isValid(imageSize), !rectangle.isInfinite, !rectangle.isNull,
              rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite else { return nil }
        let intersection = rectangle.standardized.intersection(CGRect(origin: .zero, size: imageSize))
        guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else { return nil }
        return intersection.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func displayRectangle(_ selection: CGRect, imageFrame: CGRect, imageSize: CGSize) -> CGRect {
        guard isValid(imageSize), isValid(imageFrame.size) else { return .zero }
        return CGRect(
            x: imageFrame.minX + selection.minX / imageSize.width * imageFrame.width,
            y: imageFrame.minY + selection.minY / imageSize.height * imageFrame.height,
            width: selection.width / imageSize.width * imageFrame.width,
            height: selection.height / imageSize.height * imageFrame.height
        )
    }

    static func pixelTranslation(_ translation: CGSize, imageFrame: CGRect, imageSize: CGSize) -> CGSize {
        guard isValid(imageFrame.size), isValid(imageSize),
              translation.width.isFinite, translation.height.isFinite else { return .zero }
        return CGSize(
            width: (translation.width / imageFrame.width * imageSize.width).rounded(),
            height: (translation.height / imageFrame.height * imageSize.height).rounded()
        )
    }

    static func moved(_ selection: CGRect, by translation: CGSize, imageSize: CGSize) -> CGRect? {
        guard let selection = bounded(selection, imageSize: imageSize),
              translation.width.isFinite, translation.height.isFinite else { return nil }
        return CGRect(
            x: min(max(0, selection.minX + translation.width.rounded()), imageSize.width - selection.width),
            y: min(max(0, selection.minY + translation.height.rounded()), imageSize.height - selection.height),
            width: selection.width,
            height: selection.height
        )
    }

    static func resized(_ selection: CGRect, handle: ScreenshotSelectionHandle, by translation: CGSize, imageSize: CGSize) -> CGRect? {
        guard let selection = bounded(selection, imageSize: imageSize),
              translation.width.isFinite, translation.height.isFinite else { return nil }
        let left = handle.isLeading ? min(max(0, selection.minX + translation.width.rounded()), selection.maxX - 1) : selection.minX
        let right = handle.isTrailing ? min(max(selection.minX + 1, selection.maxX + translation.width.rounded()), imageSize.width) : selection.maxX
        let top = handle.isTop ? min(max(0, selection.minY + translation.height.rounded()), selection.maxY - 1) : selection.minY
        let bottom = handle.isBottom ? min(max(selection.minY + 1, selection.maxY + translation.height.rounded()), imageSize.height) : selection.maxY
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func pixelPoint(_ point: CGPoint, imageFrame: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(0, (point.x - imageFrame.minX) / imageFrame.width), 1) * imageSize.width,
            y: min(max(0, (point.y - imageFrame.minY) / imageFrame.height), 1) * imageSize.height
        )
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
