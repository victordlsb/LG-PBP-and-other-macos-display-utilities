// Command-drag snapping: hold ⌘ while dragging a window to see the active layout's
// zones, and release over a zone to place the window there.
//
// Moving other apps' windows uses the macOS Accessibility interface, so the app
// needs Accessibility access. Nothing here talks to the monitor.

import AppKit
import ApplicationServices

enum WindowMover {
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.3)   // never hang on an unresponsive app
        return element
    }()

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// The window under a point given in Cocoa screen coordinates.
    static func window(atCocoaPoint point: NSPoint) -> AXUIElement? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(primaryHeight - point.y), &found) == .success,
              let element = found else { return focusedWindow() }
        AXUIElementSetMessagingTimeout(element, 0.3)
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == (kAXWindowRole as String) {
            return element
        }
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success, let window {
            let result = window as! AXUIElement
            AXUIElementSetMessagingTimeout(result, 0.3)
            return result
        }
        return focusedWindow()
    }

    private static func focusedWindow() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        return (window as! AXUIElement)
    }

    /// Top-left origin and size, in Accessibility (top-left based) coordinates.
    static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Places a window in a rectangle given in Cocoa screen coordinates.
    static func setFrame(_ window: AXUIElement, cocoaRect rect: NSRect) {
        var origin = CGPoint(x: rect.minX, y: primaryHeight - rect.maxY)
        var size = CGSize(width: rect.width, height: rect.height)
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        // Size, position, size: the first size can be clamped by the old screen's bounds.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
    }
}

/// Draws a layout's zones over a screen while a window is being dragged.
private final class OverlayView: NSView {
    var zones: [NSRect] = [] { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if oldValue != highlighted { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (index, zone) in zones.enumerated() {
            let path = NSBezierPath(roundedRect: zone.insetBy(dx: 4, dy: 4), xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(index == highlighted ? 0.45 : 0.12).setFill()
            path.fill()
            accent.withAlphaComponent(index == highlighted ? 1 : 0.6).setStroke()
            path.lineWidth = index == highlighted ? 3 : 1.5
            path.stroke()
        }
    }
}

final class SnapController {
    static let shared = SnapController()

    private var monitor: Any?
    private var mouseIsDown = false
    private var candidate: AXUIElement?
    private var candidateFrame: CGRect?
    private var confirmed = false          // the candidate window is really being dragged
    private var lastProbe = Date.distantPast
    private var overlay: NSWindow?
    private var overlayView: OverlayView?
    private var overlayScreen: NSScreen?
    private var target: NSRect?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset()
            mouseIsDown = true
        case .leftMouseDragged:
            mouseIsDown = true
            update()
        case .flagsChanged:
            if mouseIsDown { update() }
        case .leftMouseUp:
            finish()
        default:
            break
        }
    }

    private func update() {
        guard NSEvent.modifierFlags.contains(.command), AXIsProcessTrusted() else {
            hideOverlay()
            return
        }
        if !confirmed {
            // Only treat this as a window drag once the window under the pointer has
            // actually moved without changing size. That keeps the overlay away from
            // ⌘-drags of files or text, and from window resizes.
            guard Date().timeIntervalSince(lastProbe) > 0.04 else { return }
            lastProbe = Date()
            guard let window = candidate else {
                candidate = WindowMover.window(atCocoaPoint: NSEvent.mouseLocation)
                candidateFrame = candidate.flatMap(WindowMover.frame(of:))
                return
            }
            guard let start = candidateFrame, let now = WindowMover.frame(of: window) else { return }
            let moved = abs(now.minX - start.minX) > 2 || abs(now.minY - start.minY) > 2
            let sameSize = abs(now.width - start.width) < 2 && abs(now.height - start.height) < 2
            guard moved && sameSize else { return }
            confirmed = true
        }
        showOverlay(at: NSEvent.mouseLocation)
    }

    private func showOverlay(at point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let layout = LayoutStore.shared.layout(for: screen), !layout.zones.isEmpty else {
            hideOverlay()
            return
        }
        let rects = layout.zones.map { $0.rect(in: screen.visibleFrame) }
        // With overlapping zones, the smallest one under the pointer wins.
        let hit = rects.enumerated()
            .filter { $0.element.contains(point) }
            .min { $0.element.width * $0.element.height < $1.element.width * $1.element.height }
        target = hit?.element

        if overlay == nil {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            overlay = window
            overlayView = view
        }
        if overlayScreen != screen {
            overlay?.setFrame(screen.frame, display: true)
            overlayScreen = screen
        }
        overlayView?.zones = rects.map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        overlayView?.highlighted = hit?.offset
        overlay?.orderFrontRegardless()
    }

    private func hideOverlay() {
        overlay?.orderOut(nil)
        target = nil
    }

    private func finish() {
        if let window = candidate, let rect = target, overlay?.isVisible == true {
            // Let the system finish its own drag before placing the window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                WindowMover.setFrame(window, cocoaRect: rect)
            }
        }
        reset()
    }

    private func reset() {
        hideOverlay()
        mouseIsDown = false
        candidate = nil
        candidateFrame = nil
        confirmed = false
        lastProbe = .distantPast
    }
}
