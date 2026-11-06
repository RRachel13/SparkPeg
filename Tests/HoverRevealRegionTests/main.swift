import Foundation
import CoreGraphics

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}

let bar = CGRect(x: 0, y: 950, width: 1470, height: 32)
let center = HoverRevealRegion.centerBand(in: bar)
expect(center.width == 320, "Default exclusion must reserve 320 points")
for x in [CGFloat(0), 250, 574, 896, 1200, 1469] {
    expect(HoverRevealRegion.canReveal(at: CGPoint(x: x, y: 970), menuBar: bar, centerBand: center),
           "Both sides must wake, including the far left and right")
}
for x in [center.minX, bar.midX, center.maxX] {
    expect(!HoverRevealRegion.canReveal(at: CGPoint(x: x, y: 970), menuBar: bar, centerBand: center),
           "Center and both boundaries must never wake")
    expect(HoverRevealRegion.isInCenter(CGPoint(x: x, y: 970), menuBar: bar, centerBand: center),
           "Entering the center must also be detectable while the line is already open")
}
expect(HoverRevealRegion.canReveal(at: CGPoint(x: 250, y: bar.maxY), menuBar: bar, centerBand: center),
       "The physical top edge must wake")
for point in [CGPoint(x: -1, y: 970), CGPoint(x: 1470, y: 970),
              CGPoint(x: 250, y: 949), CGPoint(x: 250, y: 983)] {
    expect(!HoverRevealRegion.canReveal(at: point, menuBar: bar, centerBand: center),
           "Outside the screen or menu bar must not wake")
}
let camera = CGRect(x: 535, y: 950, width: 400, height: 32)
let wideCamera = HoverRevealRegion.centerBand(in: bar, cameraGap: camera)
expect(wideCamera.width == 496 && wideCamera.midX == camera.midX,
       "A camera wider than the preference must keep 48 points of padding on each side")
let wider = HoverRevealRegion.centerBand(in: bar, preferredWidth: 640)
expect(wider.width == 640, "A wider Dynamic Island setting must be respected")
expect(!HoverRevealRegion.canReveal(at: CGPoint(x: 450, y: 970), menuBar: bar, centerBand: wider),
       "Widening the center must also remove the adjacent hover activation area")
let otherBar = CGRect(x: -1920, y: -20, width: 1920, height: 24)
let otherCenter = HoverRevealRegion.centerBand(in: otherBar)
expect(otherCenter.midX == -960, "External displays must use global coordinates, not the main screen's center")
expect(HoverRevealRegion.canReveal(at: CGPoint(x: -1800, y: 0), menuBar: otherBar, centerBand: otherCenter),
       "Left-positioned external display must wake on its own left side")
expect(!HoverRevealRegion.canReveal(at: CGPoint(x: -960, y: 0), menuBar: otherBar, centerBand: otherCenter),
       "An external display without a notch must still reserve its center")
let smallBar = CGRect(x: 0, y: 0, width: 200, height: 24)
let smallCenter = HoverRevealRegion.centerBand(in: smallBar)
expect(smallCenter == smallBar, "The exclusion must stay within narrow screen bounds")
expect(!HoverRevealRegion.canReveal(at: CGPoint(x: 10, y: 10), menuBar: .zero, centerBand: .zero),
       "An empty menu bar must never wake")
print("PASS: \(checks) hover-region checks")
