import ApplicationServices
import CoreGraphics
import Foundation

enum DesktopSpaceDragPointSelector {
    /// Probe without moving/clicking the pointer. Never trial-drag controls.
    static func select(
        frame: CGRect,
        defaultPoint: CGPoint,
        buttons: [CGRect],
        direction: DesktopSpaceMoveDirection,
        isWindowBackground: (CGPoint) -> Bool
    ) -> CGPoint? {
        let delta = direction == .left ? -MissionControlDesktopSpaceMover.carryDragDistance : MissionControlDesktopSpaceMover.carryDragDistance
        let y = frame.minY + MissionControlDesktopSpaceMover.titlebarYOffset
        var candidates = [defaultPoint]
        // The gap next to the traffic lights is often the only titlebar left
        // when Brave uses vertical tabs or VS Code enables Command Center.
        if let trailingEdge = buttons.map(\.maxX).max() {
            candidates.append(CGPoint(x: trailingEdge + 8, y: y))
        }
        // Chromium can omit the standard window-button attributes even though
        // the traffic lights are visible. Probe the known-safe strip directly
        // after them before trying the tab/address-bar regions.
        for offset in [76.0, 92.0, 108.0] {
            candidates.append(CGPoint(x: frame.minX + offset, y: y))
        }
        // Bounded read-only search of the top strip, away from resize edges.
        for fraction in [0.25, 0.75, 0.125, 0.875] {
            candidates.append(CGPoint(x: frame.minX + frame.width * fraction, y: y))
        }
        return candidates.first { point in
            let end = CGPoint(x: point.x + delta, y: point.y)
            let interior = frame.insetBy(dx: 5, dy: 5)
            guard interior.contains(point), interior.contains(end),
                  !buttons.contains(where: { $0.insetBy(dx: -3, dy: -3).contains(point) || $0.insetBy(dx: -3, dy: -3).contains(end) }) else { return false }
            return isWindowBackground(point) && isWindowBackground(end)
        }
    }

    static func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func isEligibleCustomTitlebarHit(
        role: String,
        actions: Set<String>,
        belongsToTargetWindow: Bool
    ) -> Bool {
        guard belongsToTargetWindow,
              !actions.contains(kAXPressAction),
              !actions.contains(kAXShowMenuAction)
        else {
            return false
        }

        return ["AXWindow", "AXTitleBar", "AXToolbar", "AXGroup"].contains(role)
    }
}
