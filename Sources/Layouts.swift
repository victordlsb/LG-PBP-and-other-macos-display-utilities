// Window layouts: named sets of zones, stored as fractions of a screen's usable area
// so the same layout fits any screen size.

import AppKit

/// A zone as fractions (0...1) of the screen's visible frame; `y` is measured from the top.
struct Zone: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double

    /// The zone in Cocoa screen coordinates (origin bottom-left).
    func rect(in visible: NSRect) -> NSRect {
        NSRect(x: visible.minX + x * visible.width,
               y: visible.maxY - (y + h) * visible.height,
               width: w * visible.width,
               height: h * visible.height)
    }
}

struct Layout: Codable, Equatable {
    var id: String
    var name: String
    var zones: [Zone]
}

final class LayoutStore {
    static let shared = LayoutStore()

    private struct File: Codable {
        var layouts: [Layout]
        var active: [String: String]   // screen key -> layout id
    }

    private(set) var layouts: [Layout]
    private var active: [String: String]
    private let url: URL

    private static let defaults: [Layout] = [
        Layout(id: "halves", name: "Halves", zones: [Zone(x: 0, y: 0, w: 0.5, h: 1), Zone(x: 0.5, y: 0, w: 0.5, h: 1)]),
        Layout(id: "thirds", name: "Thirds", zones: (0..<3).map { Zone(x: Double($0) / 3, y: 0, w: 1.0 / 3, h: 1) }),
        Layout(id: "wide-centre", name: "Wide Centre", zones: [
            Zone(x: 0, y: 0, w: 0.25, h: 1), Zone(x: 0.25, y: 0, w: 0.5, h: 1), Zone(x: 0.75, y: 0, w: 0.25, h: 1)]),
        Layout(id: "60-40", name: "60 / 40", zones: [Zone(x: 0, y: 0, w: 0.6, h: 1), Zone(x: 0.6, y: 0, w: 0.4, h: 1)]),
        Layout(id: "quarters", name: "Quarters", zones: [
            Zone(x: 0, y: 0, w: 0.5, h: 0.5), Zone(x: 0.5, y: 0, w: 0.5, h: 0.5),
            Zone(x: 0, y: 0.5, w: 0.5, h: 0.5), Zone(x: 0.5, y: 0.5, w: 0.5, h: 0.5)]),
    ]

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LG PBP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("layouts.json")
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), !file.layouts.isEmpty {
            layouts = file.layouts
            active = file.active
        } else {
            layouts = Self.defaults
            active = [:]
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(File(layouts: layouts, active: active)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Identifies a screen by display model and shape, so the LG keeps a separate
    /// choice for full width, PBP 75/25 and PBP 50/50.
    static func key(for screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let aspect = screen.frame.width / max(screen.frame.height, 1)
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(Int((aspect * 10).rounded()))"
    }

    func layout(for screen: NSScreen) -> Layout? {
        if let id = active[Self.key(for: screen)], let chosen = layouts.first(where: { $0.id == id }) { return chosen }
        let wide = screen.frame.width / max(screen.frame.height, 1) > 2.1
        return layouts.first { $0.id == (wide ? "thirds" : "halves") } ?? layouts.first
    }

    func setActive(_ id: String, for screen: NSScreen) {
        active[Self.key(for: screen)] = id
        save()
    }

    func replaceAll(_ new: [Layout]) {
        layouts = new
        save()
    }
}
