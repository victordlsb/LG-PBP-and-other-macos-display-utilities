// LG PBP — menu bar app: PBP on the LG UltraFine 40U990A, iPad as a display, and window layouts.
//
// The app only talks to the monitor when you pick a menu item or press the hotkey,
// and then it sends a single "set PBP" command (preceded by an input switch when a
// fixed left side is chosen and PBP is being turned on). It also reads the PBP state
// (0xD7, a read only) when the menu opens and before a toggle, because over some links
// (HDMI through an adapter) macOS does not change the picture's shape with PBP, so
// the shape alone can be wrong. When the monitor does not answer, the shape is used.

import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A layout chosen for a screen from the menu.
private final class LayoutChoice: NSObject {
    let screen: NSScreen
    let layoutID: String
    init(screen: NSScreen, layoutID: String) {
        self.screen = screen
        self.layoutID = layoutID
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let queue = DispatchQueue(label: "lgpbp.monitor")
    private var busy = false
    /// The last PBP state read from or sent to the monitor; nil until then, and the
    /// inferred state is used meanwhile. A change made elsewhere (the other Mac, the
    /// joystick) shows up the next time the menu opens or the toggle is used.
    private var monitorState: PBPMode?
    private var modeItems: [NSMenuItem] = []
    private var iPadBusy = false
    private var lastError: String?
    private var hotKeys: [EventHotKeyRef?] = []
    private var widgetWork: DispatchWorkItem?
    private var widgetNote: String?

    /// The layout the hotkey turns on; remembers the last one you picked.
    private var lastLayout: PBPMode {
        get { PBPMode(rawValue: UInt16(UserDefaults.standard.integer(forKey: "lastLayout"))).flatMap { $0 == .off ? nil : $0 } ?? .half }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: "lastLayout") }
    }

    /// The input to put on the left when PBP is turned on, or nil to leave it to the
    /// monitor (which puts the input on screen on the left). Stored per Mac: set it on
    /// the Mac that should not be on the left.
    private var pbpLeft: LGInput? {
        get { LGInput(rawValue: UInt16(UserDefaults.standard.integer(forKey: "pbpLeft"))).flatMap { $0.switchConfirmed ? $0 : nil } }
        set { UserDefaults.standard.set(Int(newValue?.rawValue ?? 0), forKey: "pbpLeft") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        registerHotKey()
        refreshIcon()
        SnapController.shared.start()
        ScrollReverser.shared.start()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = currentState()
        modeItems = []

        if state == nil {
            menu.addItem(disabled("LG UltraFine not connected"))
            menu.addItem(.separator())
        }
        for mode in [PBPMode.half, .wide, .off] {
            let item = NSMenuItem(title: mode.label, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(mode.rawValue)
            item.state = state == mode ? .on : .off
            item.isEnabled = state != nil && !busy
            menu.addItem(item)
            modeItems.append(item)
        }
        // Ask the monitor and correct the checkmark when the answer arrives.
        if state != nil && !busy {
            queue.async {
                guard let read = try? LGMonitor.readMode() else { return }
                DispatchQueue.main.async {
                    self.monitorState = read
                    for item in self.modeItems { item.state = item.tag == Int(read.rawValue) ? .on : .off }
                    self.refreshIcon()
                }
            }
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Toggle PBP", action: #selector(toggle), keyEquivalent: "p")
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        toggle.isEnabled = state != nil && !busy
        menu.addItem(toggle)

        let leftMenu = NSMenu()
        leftMenu.autoenablesItems = false
        let choices: [LGInput?] = [nil] + LGInput.allCases.filter(\.switchConfirmed)
        for input in choices {
            let item = NSMenuItem(title: input?.label ?? "Input on Screen", action: #selector(pickLeft(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(input?.rawValue ?? 0)
            item.state = pbpLeft == input ? .on : .off
            leftMenu.addItem(item)
        }
        let leftItem = NSMenuItem(title: "Left Side in PBP: \(pbpLeft?.label ?? "Input on Screen")", action: nil, keyEquivalent: "")
        leftItem.submenu = leftMenu
        menu.addItem(leftItem)

        // One Mac full screen: turns PBP off if needed, then switches input.
        menu.addItem(.separator())
        let own = LGMonitor.ownInput()
        for input in LGInput.allCases.filter(\.switchConfirmed) {
            let who = own == nil ? "" : (input == own ? "This Mac — " : "Other Mac — ")
            let isOther = own != nil && input != own
            let item = NSMenuItem(title: "Full Screen: \(who)\(input.label)", action: #selector(pickFullScreen(_:)),
                                  keyEquivalent: isOther ? "o" : "")
            item.keyEquivalentModifierMask = [.control, .option, .command]
            item.target = self
            item.tag = Int(input.rawValue)
            item.isEnabled = state != nil && !busy
            menu.addItem(item)
        }

        // iPad as an extended display (Sidecar).
        menu.addItem(.separator())
        let iPads = Sidecar.devices
        if iPads.isEmpty {
            menu.addItem(disabled("No iPad in reach"))
        }
        for (index, device) in iPads.enumerated() {
            let item = NSMenuItem(title: "\(Sidecar.name(of: device)) as Display", action: #selector(pickIPad(_:)),
                                  keyEquivalent: index == 0 ? "i" : "")
            item.keyEquivalentModifierMask = [.control, .option, .command]
            item.target = self
            item.representedObject = device
            item.state = Sidecar.isConnected(device) ? .on : .off
            item.isEnabled = !iPadBusy
            menu.addItem(item)
        }

        // Window layouts, one submenu per screen.
        menu.addItem(.separator())
        menu.addItem(disabled("Window Layouts — hold ⌘ while dragging a window"))
        if !AXIsProcessTrusted() {
            let grant = NSMenuItem(title: "Enable Window Snapping…", action: #selector(requestAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        for screen in NSScreen.screens {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let current = LayoutStore.shared.layout(for: screen)
            for layout in LayoutStore.shared.layouts {
                let item = NSMenuItem(title: layout.name, action: #selector(pickLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = LayoutChoice(screen: screen, layoutID: layout.id)
                item.state = layout.id == current?.id ? .on : .off
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let edit = NSMenuItem(title: "Edit Layouts…", action: #selector(editLayouts(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = screen
            submenu.addItem(edit)

            let parent = NSMenuItem(title: "\(screen.localizedName): \(current?.name ?? "none")", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }

        // Desktop widget positions, remembered per screen setup.
        menu.addItem(.separator())
        menu.addItem(disabled("Desktop Widgets"))
        let saveWidgets = NSMenuItem(title: "Save Widget Positions for This Screen Setup", action: #selector(saveWidgetPositions), keyEquivalent: "")
        saveWidgets.target = self
        menu.addItem(saveWidgets)
        let restore = NSMenuItem(title: "Restore Widget Positions", action: #selector(restoreWidgetPositions), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = WidgetLayouts.hasSavedForCurrentSetup
        menu.addItem(restore)
        let auto = NSMenuItem(title: "Restore Automatically When Screens Change", action: #selector(toggleWidgetAuto), keyEquivalent: "")
        auto.target = self
        auto.state = WidgetLayouts.auto ? .on : .off
        menu.addItem(auto)
        if let widgetNote { menu.addItem(disabled(widgetNote)) }

        if let lastError {
            menu.addItem(.separator())
            menu.addItem(disabled("Last command failed: \(lastError)"))
        }
        menu.addItem(.separator())
        let reverse = NSMenuItem(title: "Reverse Mouse Wheel (trackpad stays natural)", action: #selector(toggleReverseWheel), keyEquivalent: "")
        reverse.target = self
        reverse.state = ScrollReverser.shared.enabled ? .on : .off
        menu.addItem(reverse)
        if ScrollReverser.shared.enabled && !ScrollReverser.shared.active {
            let grant = NSMenuItem(title: "Grant Accessibility to Reverse the Wheel…", action: #selector(requestAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit LG PBP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The monitor's last known PBP state, or the one inferred from the picture.
    private func currentState() -> PBPMode? {
        guard LGMonitor.displayID() != nil else { return nil }
        return monitorState ?? LGMonitor.inferredMode()
    }

    @objc private func screensChanged() {
        refreshIcon()
        // Wait for the screens to settle before touching widget positions.
        widgetWork?.cancel()
        guard WidgetLayouts.auto else { return }
        let work = DispatchWorkItem { [weak self] in self?.restoreWidgets(automatic: true) }
        widgetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @objc private func refreshIcon() {
        let state = currentState()
        // Remember the PBP mode in use even when it was chosen on the monitor or in the terminal,
        // so the toggle always returns to the last one used.
        if let state, state != .off { lastLayout = state }
        let symbol = (state == .half || state == .wide) ? "rectangle.split.2x1.fill" : "rectangle.split.2x1"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LG PBP") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "PBP"
        }
        statusItem.button?.appearsDisabled = state == nil
    }

    // MARK: Actions

    @objc private func pick(_ sender: NSMenuItem) {
        guard let mode = PBPMode(rawValue: UInt16(sender.tag)) else { return }
        send(mode)
    }

    @objc func toggle() {
        guard !busy, LGMonitor.displayID() != nil else { NSSound.beep(); return }
        // Ask the monitor first: the picture's shape can be wrong (see the top of this file).
        busy = true
        queue.async {
            let read = try? LGMonitor.readMode()
            DispatchQueue.main.async {
                self.busy = false
                if let read { self.monitorState = read }
                guard let state = self.currentState() else { NSSound.beep(); return }
                self.send(state == .off ? self.lastLayout : .off)
            }
        }
    }

    @objc private func pickFullScreen(_ sender: NSMenuItem) {
        guard let input = LGInput(rawValue: UInt16(sender.tag)) else { return }
        showFullScreen(input)
    }

    /// Hotkey: shows the other Mac full screen (the one on the other input).
    func showOtherMac() {
        guard let own = LGMonitor.ownInput(),
              let other = LGInput.allCases.first(where: { $0.switchConfirmed && $0 != own }) else { NSSound.beep(); return }
        showFullScreen(other)
    }

    private func showFullScreen(_ input: LGInput) {
        guard !busy, LGMonitor.displayID() != nil else { NSSound.beep(); return }
        busy = true
        queue.async {
            var failure: String?
            do {
                // Ask the monitor whether PBP is on; the picture's shape can be wrong.
                let read = try? LGMonitor.readMode()
                let pbpOn = (read ?? LGMonitor.inferredMode() ?? .off) != .off
                try LGMonitor.showFullScreen(input, pbpOn: pbpOn)
            } catch { failure = "\(error)" }
            Thread.sleep(forTimeInterval: failure == nil ? 3 : 0)
            DispatchQueue.main.async {
                self.busy = false
                self.lastError = failure
                if failure == nil { self.monitorState = .off }
                if failure != nil { NSSound.beep() }
                self.refreshIcon()
            }
        }
    }

    @objc private func pickLeft(_ sender: NSMenuItem) {
        pbpLeft = LGInput(rawValue: UInt16(sender.tag))
    }

    private func send(_ mode: PBPMode) {
        guard !busy else { return }
        busy = true
        if mode != .off { lastLayout = mode }
        // Only switch inputs when PBP is being turned on: changing between 50/50 and
        // 75/25 keeps the sides, and an input switch during PBP is untested.
        let left = mode != .off && currentState() == .off ? pbpLeft : nil
        queue.async {
            var failure: String?
            do {
                if let left { try LGMonitor.startPBP(mode, left: left) } else { try LGMonitor.setPBP(mode) }
            } catch { failure = "\(error)" }
            // The monitor needs a few seconds to switch; hold further commands until then.
            Thread.sleep(forTimeInterval: failure == nil ? 3 : 0)
            DispatchQueue.main.async {
                self.busy = false
                self.lastError = failure
                if failure == nil { self.monitorState = mode }
                if failure != nil { NSSound.beep() }
                self.refreshIcon()
            }
        }
    }

    @objc private func pickIPad(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? NSObject else { return }
        toggleIPad(device)
    }

    /// Hotkey: connects the first iPad in reach as a display, or disconnects it.
    func toggleFirstIPad() {
        guard let device = Sidecar.devices.first else { NSSound.beep(); return }
        toggleIPad(device)
    }

    private func toggleIPad(_ device: NSObject) {
        guard !iPadBusy else { return }
        iPadBusy = true
        Sidecar.setConnected(device, !Sidecar.isConnected(device)) { failure in
            self.iPadBusy = false
            self.lastError = failure.map { "iPad display: \($0)" }
            if failure != nil { NSSound.beep() }
        }
    }

    @objc private func pickLayout(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LayoutChoice else { return }
        LayoutStore.shared.setActive(choice.layoutID, for: choice.screen)
    }

    @objc private func editLayouts(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        LayoutEditor.open(on: screen)
    }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility.
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func saveWidgetPositions() {
        do {
            try WidgetLayouts.saveCurrent()
            widgetNote = "Saved for this screen setup"
        } catch {
            widgetNote = "Could not save: \(error)"
            NSSound.beep()
        }
    }

    @objc private func restoreWidgetPositions() { restoreWidgets(automatic: false) }

    @objc private func toggleWidgetAuto() { WidgetLayouts.auto.toggle() }

    @objc private func toggleReverseWheel() { ScrollReverser.shared.enabled.toggle() }

    private func restoreWidgets(automatic: Bool) {
        queue.async {
            let note: String?
            do {
                switch try WidgetLayouts.restore() {
                case .applied: note = "Restored"
                case .alreadyInPlace: note = automatic ? nil : "Already in place"
                case .nothingSaved: note = automatic ? nil : "Nothing saved for this screen setup"
                case .outdated: note = "Widgets were added or removed — save positions again"
                }
            } catch {
                note = "Could not restore: \(error)"
            }
            DispatchQueue.main.async { if note != nil || !automatic { self.widgetNote = note } }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = "Launch at Login: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    // MARK: Global hotkeys (Control-Option-Command-P for PBP, -I for the iPad, -O for the other Mac full screen)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let which = id.id
            DispatchQueue.main.async {
                switch which {
                case 1: AppDelegate.shared.toggle()
                case 3: AppDelegate.shared.showOtherMac()
                default: AppDelegate.shared.toggleFirstIPad()
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        for (number, key, name) in [(UInt32(1), kVK_ANSI_P, "P"), (UInt32(2), kVK_ANSI_I, "I"), (UInt32(3), kVK_ANSI_O, "O")] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C47_5042), id: number)   // 'LGPB'
            let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey | cmdKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
            if status != noErr { lastError = "Hotkey ⌃⌥⌘\(name) is already taken by another app" }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
