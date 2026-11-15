// Saves and restores the positions of macOS desktop widgets, one arrangement per
// screen setup (for example: MacBook alone, LG full width, LG in PBP, LG + iPad).
//
// macOS has no interface for this. The positions live in Notification Center's
// preferences under widgets > DesktopWidgetPlacementStorage. Restoring writes that
// one value back through `defaults import` and restarts Notification Center so it
// reloads; the widgets disappear for a second or two while it does.

import AppKit

enum WidgetError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case .message(let text) = self { return text }
        return "unknown"
    }
}

enum WidgetLayouts {
    enum Outcome { case applied, alreadyInPlace, nothingSaved, outdated }

    private static let domain = "com.apple.notificationcenterui"

    private struct Saved: Codable {
        var placement: Data
        var widgetIDs: [String]
    }

    private struct File: Codable {
        var setups: [String: Saved] = [:]
        var auto = false
    }

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LG PBP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widgets.json")
    }()

    private static func load() -> File {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    private static func store(_ file: File) {
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: .atomic) }
    }

    /// Identifies the current screen setup: the main screen first, then the others.
    static func setupKey() -> String {
        let screens = NSScreen.screens
        guard let main = screens.first else { return "none" }
        let others = screens.dropFirst().map(LayoutStore.key(for:)).sorted()
        return ([LayoutStore.key(for: main)] + others).joined(separator: "|")
    }

    static var hasSavedForCurrentSetup: Bool { load().setups[setupKey()] != nil }

    static var auto: Bool {
        get { load().auto }
        set { var file = load(); file.auto = newValue; store(file) }
    }

    // MARK: Notification Center preferences

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WidgetError.message("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(process.terminationStatus))")
        }
        return data
    }

    private static func readPreferences() throws -> [String: Any] {
        let data = try run("/usr/bin/defaults", ["export", domain, "-"])
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw WidgetError.message("could not read the widget settings")
        }
        return plist
    }

    private static func placement(in preferences: [String: Any]) throws -> Data {
        guard let widgets = preferences["widgets"] as? [String: Any],
              let data = widgets["DesktopWidgetPlacementStorage"] as? Data else {
            throw WidgetError.message("no desktop widget positions found")
        }
        return data
    }

    /// The identifiers of the widgets a placement blob puts on the desktop.
    private static func widgetIDs(in placement: Data) -> Set<String> {
        var ids = Set<String>()
        guard let root = try? PropertyListSerialization.propertyList(from: placement, format: nil) as? [String: Any] else { return ids }
        for display in root["NumberedDisplays"] as? [[String: Any]] ?? [] {
            for resolution in display["Resolutions"] as? [[String: Any]] ?? [] {
                for group in resolution["Groups"] as? [[String: Any]] ?? [] {
                    for item in group["Items"] as? [[String: Any]] ?? [] {
                        if let id = item["Identifier"] as? String { ids.insert(id) }
                    }
                }
            }
        }
        return ids
    }

    private static func sameArrangement(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? PropertyListSerialization.propertyList(from: a, format: nil) as? NSDictionary,
              let y = try? PropertyListSerialization.propertyList(from: b, format: nil) as? NSDictionary else { return a == b }
        return x.isEqual(y)
    }

    // MARK: Save and restore

    static func saveCurrent() throws {
        let current = try placement(in: readPreferences())
        var file = load()
        file.setups[setupKey()] = Saved(placement: current, widgetIDs: widgetIDs(in: current).sorted())
        store(file)
    }

    static func restore() throws -> Outcome {
        guard let saved = load().setups[setupKey()] else { return .nothingSaved }
        var preferences = try readPreferences()
        let current = try placement(in: preferences)
        if sameArrangement(current, saved.placement) { return .alreadyInPlace }
        // If widgets were added or removed since saving, the saved arrangement no longer
        // describes the desktop; applying it could drop or orphan widgets, so refuse.
        guard widgetIDs(in: current) == Set(saved.widgetIDs) else { return .outdated }

        var widgets = preferences["widgets"] as? [String: Any] ?? [:]
        widgets["DesktopWidgetPlacementStorage"] = saved.placement
        preferences["widgets"] = widgets

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lgpbp-widgets-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0).write(to: file)
        try run("/usr/bin/defaults", ["import", domain, file.path])
        try run("/usr/bin/killall", ["NotificationCenter"])   // it relaunches by itself and reloads the positions
        return .applied
    }
}
