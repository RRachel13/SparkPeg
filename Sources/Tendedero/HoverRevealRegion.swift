import Foundation
import CoreGraphics

/// Menu-bar hover geometry in global screen coordinates. The central strip
/// belongs to the camera housing and any Dynamic Island extension.
enum HoverRevealRegion {
    static let defaultCenterWidth: CGFloat = 320
    static let cameraPadding: CGFloat = 48

    static func centerBand(in menuBar: CGRect, cameraGap: CGRect? = nil,
                           preferredWidth: CGFloat = defaultCenterWidth) -> CGRect {
        let width = min(menuBar.width, max(preferredWidth,
                                          cameraGap.map { $0.width + cameraPadding * 2 } ?? 0))
        let center = cameraGap?.midX ?? menuBar.midX
        let x = max(menuBar.minX, min(center - width / 2, menuBar.maxX - width))
        return CGRect(x: x, y: menuBar.minY, width: width, height: menuBar.height)
    }

    static func isInCenter(_ point: CGPoint, menuBar: CGRect, centerBand: CGRect) -> Bool {
        contains(point, in: menuBar) && point.x >= centerBand.minX && point.x <= centerBand.maxX
    }

    static func canReveal(at point: CGPoint, menuBar: CGRect, centerBand: CGRect) -> Bool {
        contains(point, in: menuBar) && !isInCenter(point, menuBar: menuBar, centerBand: centerBand)
    }

    private static func contains(_ point: CGPoint, in bar: CGRect) -> Bool {
        // Include the physical top edge: moving all the way up must work too.
        !bar.isEmpty && point.x >= bar.minX && point.x < bar.maxX
            && point.y >= bar.minY && point.y <= bar.maxY
    }
}
