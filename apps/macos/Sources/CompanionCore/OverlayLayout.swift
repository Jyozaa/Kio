import Foundation

public struct OverlayFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public var maxY: Double { y + height }
}

public struct OverlayScreenGeometry: Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let visibleTop: Double
    public let safeTop: Double
    public let hasNotch: Bool

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        visibleTop: Double,
        safeTop: Double,
        hasNotch: Bool
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.visibleTop = visibleTop
        self.safeTop = safeTop
        self.hasNotch = hasNotch
    }

    public func overlayFrame(width requestedWidth: Double, height: Double) -> OverlayFrame {
        let width = min(max(40, requestedWidth), max(40, self.width - 32))
        let top = hasNotch ? y + self.height - safeTop : visibleTop
        let gap = 0.0
        return OverlayFrame(
            x: x + (self.width - width) / 2,
            y: top - gap - height,
            width: width,
            height: height
        )
    }
}
