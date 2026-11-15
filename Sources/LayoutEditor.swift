// Full-screen editor for window layouts: draw zones with the mouse on the screen
// they will apply to.

import AppKit

private final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class LayoutEditor: NSObject, NSTextFieldDelegate {
    private static var current: LayoutEditor?

    private let screen: NSScreen
    fileprivate var layouts: [Layout]
    fileprivate var index: Int
    private let window: EditorWindow
    private let canvas: CanvasView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "")

    static func open(on screen: NSScreen) {
        current?.close()
        let editor = LayoutEditor(screen: screen)
        current = editor
        NSApp.activate(ignoringOtherApps: true)
        editor.window.makeKeyAndOrderFront(nil)
        editor.window.makeFirstResponder(editor.canvas)
    }

    private init(screen: NSScreen) {
        self.screen = screen
        layouts = LayoutStore.shared.layouts
        let activeID = LayoutStore.shared.layout(for: screen)?.id
        index = layouts.firstIndex { $0.id == activeID } ?? 0

        window = EditorWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isReleasedWhenClosed = false

        // The usable area (below the menu bar, clear of the Dock), in the canvas's flipped coordinates.
        let frame = screen.frame, visible = screen.visibleFrame
        let area = NSRect(x: visible.minX - frame.minX, y: frame.maxY - visible.maxY, width: visible.width, height: visible.height)
        canvas = CanvasView(frame: NSRect(origin: .zero, size: frame.size), area: area)
        super.init()
        canvas.editor = self
        window.contentView = canvas
        buildToolbar(in: area)
        refreshControls()
    }

    private func buildToolbar(in area: NSRect) {
        let width: CGFloat = min(780, area.width - 40), height: CGFloat = 76
        let bar = NSVisualEffectView(frame: NSRect(x: area.midX - width / 2, y: area.minY + 16, width: width, height: height))
        bar.material = .hudWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.layer?.masksToBounds = true

        popup.target = self
        popup.action = #selector(layoutPicked)
        nameField.delegate = self
        nameField.placeholderString = "Layout name"
        nameField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let controls = NSStackView(views: [
            popup, nameField,
            NSButton(title: "New", target: self, action: #selector(newLayout)),
            NSButton(title: "Delete", target: self, action: #selector(deleteLayout)),
            NSButton(title: "Cancel", target: self, action: #selector(cancel)),
            NSButton(title: "Save", target: self, action: #selector(save)),
        ])
        controls.orientation = .horizontal
        controls.spacing = 8

        let hint = NSTextField(labelWithString:
            "Drag to draw a zone · drag a zone to move it · drag its edge to resize · Delete removes it · hold ⌥ for free placement")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [controls, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.frame = bar.bounds
        stack.autoresizingMask = [.width, .height]
        bar.addSubview(stack)
        canvas.addSubview(bar)
    }

    fileprivate func refreshControls() {
        popup.removeAllItems()
        for layout in layouts { popup.addItem(withTitle: layout.name.isEmpty ? "Untitled" : layout.name) }
        // addItem(withTitle:) drops duplicate titles; fall back to selecting by position when counts match.
        if popup.numberOfItems == layouts.count { popup.selectItem(at: index) }
        nameField.stringValue = layouts[index].name
        canvas.selected = nil
        canvas.needsDisplay = true
    }

    @objc private func layoutPicked() {
        guard popup.indexOfSelectedItem >= 0, popup.indexOfSelectedItem < layouts.count else { return }
        index = popup.indexOfSelectedItem
        refreshControls()
    }

    func controlTextDidChange(_ notification: Notification) {
        layouts[index].name = nameField.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let name = nameField.stringValue
        refreshControls()
        nameField.stringValue = name
    }

    @objc private func newLayout() {
        layouts.append(Layout(id: UUID().uuidString, name: "Layout \(layouts.count + 1)", zones: []))
        index = layouts.count - 1
        refreshControls()
        window.makeFirstResponder(canvas)
    }

    @objc private func deleteLayout() {
        guard layouts.count > 1 else { NSSound.beep(); return }
        layouts.remove(at: index)
        index = min(index, layouts.count - 1)
        refreshControls()
    }

    @objc fileprivate func cancel() { close() }

    @objc private func save() {
        window.makeFirstResponder(canvas)   // commit a name still being typed
        for i in layouts.indices where layouts[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
            layouts[i].name = "Untitled"
        }
        LayoutStore.shared.replaceAll(layouts)
        LayoutStore.shared.setActive(layouts[index].id, for: screen)
        close()
    }

    private func close() {
        window.orderOut(nil)
        if LayoutEditor.current === self { LayoutEditor.current = nil }
    }
}

private final class CanvasView: NSView {
    weak var editor: LayoutEditor?
    var selected: Int?
    private let area: NSRect

    private enum Drag {
        case none
        case create(anchor: NSPoint)
        case move(offset: NSPoint)
        case resize(left: Bool, right: Bool, top: Bool, bottom: Bool)
    }
    private var drag = Drag.none

    // Grid the zones snap to: sixtieths across (gives halves, thirds, quarters, fifths), twelfths down.
    private let columns = 60.0, rows = 12.0
    private let minimum = 0.05

    init(frame: NSRect, area: NSRect) {
        self.area = area
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var zones: [Zone] {
        get { editor.map { $0.layouts[$0.index].zones } ?? [] }
        set { if let editor { editor.layouts[editor.index].zones = newValue } }
    }

    private func rect(of zone: Zone) -> NSRect {
        NSRect(x: area.minX + zone.x * area.width, y: area.minY + zone.y * area.height,
               width: zone.w * area.width, height: zone.h * area.height)
    }

    /// The point as fractions of the usable area, optionally snapped to the grid.
    private func fraction(_ point: NSPoint, snap: Bool) -> NSPoint {
        var x = min(max((point.x - area.minX) / area.width, 0), 1)
        var y = min(max((point.y - area.minY) / area.height, 0), 1)
        if snap && !NSEvent.modifierFlags.contains(.option) {
            x = (x * columns).rounded() / columns
            y = (y * rows).rounded() / rows
        }
        return NSPoint(x: x, y: y)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let accent = NSColor.controlAccentColor
        for (i, zone) in zones.enumerated() {
            let r = rect(of: zone)
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(i == selected ? 0.55 : 0.3).setFill()
            path.fill()
            (i == selected ? NSColor.white : accent).setStroke()
            path.lineWidth = i == selected ? 3 : 1.5
            path.stroke()

            let text = "\(i + 1)\n\(Int((zone.w * 100).rounded()))% × \(Int((zone.h * 100).rounded()))%" as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(in: NSRect(x: r.minX, y: r.midY - size.height / 2, width: r.width, height: size.height),
                      withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // With overlapping zones, the smallest one under the pointer wins.
        let hit = zones.enumerated()
            .filter { rect(of: $0.element).contains(point) }
            .min { $0.element.w * $0.element.h < $1.element.w * $1.element.h }

        if let hit {
            selected = hit.offset
            let r = rect(of: hit.element)
            let grab: CGFloat = 12
            let left = point.x - r.minX < grab, right = r.maxX - point.x < grab
            let top = point.y - r.minY < grab, bottom = r.maxY - point.y < grab
            if left || right || top || bottom {
                drag = .resize(left: left, right: right && !left, top: top, bottom: bottom && !top)
            } else {
                let f = fraction(point, snap: false)
                drag = .move(offset: NSPoint(x: f.x - hit.element.x, y: f.y - hit.element.y))
            }
        } else {
            selected = nil
            drag = .create(anchor: fraction(point, snap: true))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var all = zones

        switch drag {
        case .none:
            return
        case .create(let anchor):
            let f = fraction(point, snap: true)
            let zone = Zone(x: min(anchor.x, f.x), y: min(anchor.y, f.y), w: abs(f.x - anchor.x), h: abs(f.y - anchor.y))
            if let selected, selected < all.count {
                all[selected] = zone
            } else {
                all.append(zone)
                selected = all.count - 1
            }
        case .move(let offset):
            guard let selected, selected < all.count else { return }
            let f = fraction(point, snap: false)
            var zone = all[selected]
            let snapped = fraction(NSPoint(x: area.minX + (f.x - offset.x) * area.width,
                                           y: area.minY + (f.y - offset.y) * area.height), snap: true)
            zone.x = min(max(snapped.x, 0), 1 - zone.w)
            zone.y = min(max(snapped.y, 0), 1 - zone.h)
            all[selected] = zone
        case .resize(let left, let right, let top, let bottom):
            guard let selected, selected < all.count else { return }
            let f = fraction(point, snap: true)
            var zone = all[selected]
            let maxX = zone.x + zone.w, maxY = zone.y + zone.h
            if left { zone.x = min(f.x, maxX - minimum); zone.w = maxX - zone.x }
            if right { zone.w = max(f.x - zone.x, minimum) }
            if top { zone.y = min(f.y, maxY - minimum); zone.h = maxY - zone.y }
            if bottom { zone.h = max(f.y - zone.y, minimum) }
            all[selected] = zone
        }
        zones = all
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .create = drag, let selected, selected < zones.count {
            let zone = zones[selected]
            if zone.w < minimum || zone.h < minimum {   // too small to be a deliberate zone
                var all = zones
                all.remove(at: selected)
                zones = all
                self.selected = nil
            }
        }
        drag = .none
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:   // Delete, Forward Delete
            guard let selected, selected < zones.count else { return }
            var all = zones
            all.remove(at: selected)
            zones = all
            self.selected = nil
            needsDisplay = true
        case 53:        // Escape
            editor?.cancel()
        default:
            super.keyDown(with: event)
        }
    }
}
