// Makes the keyboard's volume keys change the LG's speaker volume.
//
// The Mac sends sound to the LG over DisplayPort, and macOS has no volume control for
// DisplayPort or HDMI audio: it plays at full level and the keys do nothing. So while
// the LG is the sound output, this catches the volume-up, volume-down and mute keys and
// sets the monitor's own volume instead (DDC 0x62 through `LGMonitor`). With any other
// output (the Mac's speakers, headphones) the keys are left alone.
//
// Mute only sets the volume to 0 and remembers the level to go back to; the monitor's
// mute code is not used. Each press changes the volume by one point (out of 100),
// which is what the owner asked for; holding the key repeats.
//
// Needs the Accessibility permission, like window snapping.

import AppKit
import CoreAudio

final class VolumeKeys {
    static let shared = VolumeKeys()

    /// Stored per Mac; on unless turned off in the menu.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "volumeKeys") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "volumeKeys")
            update()
        }
    }

    /// True while the event tap is installed.
    var active: Bool { tap != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?

    // Only touched on `LGMonitor.queue`.
    private var level: Int?
    private var maxLevel = Int(LGMonitor.volumeCap)
    private var levelKnownAt = Date.distantPast
    private var levelBeforeMute: Int?
    /// After this long the level is read again, in case it was changed on the joystick
    /// or from the other Mac.
    private static let levelLifetime: TimeInterval = 5

    private enum Key { case up, down, mute }

    func start() { update() }

    private func update() {
        if enabled { install() } else { remove() }
    }

    // MARK: Event tap

    private static let systemDefined = CGEventType(rawValue: 14)!   // NX_SYSDEFINED

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << VolumeKeys.systemDefined.rawValue
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = VolumeKeys.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return VolumeKeys.shared.handle(event) ? nil : Unmanaged.passUnretained(event)
        }
        // Creating the tap fails until the Accessibility permission is granted; keep
        // trying quietly so it starts as soon as the permission is given.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: nil) else {
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    guard let self, self.enabled else { return }
                    if AXIsProcessTrusted() { self.install() }
                }
            }
            return
        }
        retry?.invalidate()
        retry = nil
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func remove() {
        retry?.invalidate()
        retry = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    /// Returns true when the event was a volume key meant for the LG, which is then
    /// swallowed so macOS does not show its "no volume control" sign.
    private func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }   // aux control buttons
        let data = ns.data1
        let key: Key
        switch (data & 0xFFFF_0000) >> 16 {
        case 0: key = .up       // NX_KEYTYPE_SOUND_UP
        case 1: key = .down     // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute     // NX_KEYTYPE_MUTE
        default: return false
        }
        guard VolumeKeys.lgIsSoundOutput(), LGMonitor.displayID() != nil else { return false }
        let isDown = (data & 0xFF00) >> 8 == 0x0A
        let isRepeat = data & 0x1 == 1
        guard isDown, !(key == .mute && isRepeat) else { return true }   // key up: swallow only
        if AppDelegate.shared?.monitorBusy == true { NSSound.beep(); return true }
        LGMonitor.queue.async { self.press(key) }
        return true
    }

    // MARK: Volume

    private func press(_ key: Key) {
        if level == nil || Date().timeIntervalSince(levelKnownAt) > Self.levelLifetime {
            if let read = try? LGMonitor.readVolume() {
                if read.level != 0 { levelBeforeMute = nil }   // changed elsewhere since the mute
                level = Int(read.level)
                maxLevel = Int(read.max)
                levelKnownAt = Date()
            }
        }
        guard let current = level else {
            DispatchQueue.main.async { NSSound.beep() }
            return
        }
        let step = 1
        var target = current
        switch key {
        case .up:
            target = min(maxLevel, current + step)
            levelBeforeMute = nil
        case .down:
            target = max(0, current - step)
            levelBeforeMute = nil
        case .mute:
            if let before = levelBeforeMute {
                target = before
                levelBeforeMute = nil
            } else if current > 0 {
                levelBeforeMute = current
                target = 0
            }
        }
        if target != current {
            do {
                try LGMonitor.setVolume(UInt16(target))
            } catch {
                level = nil
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
        }
        level = target
        levelKnownAt = Date()
        let fraction = Double(target) / Double(max(maxLevel, 1))
        DispatchQueue.main.async { VolumeHUD.shared.show(fraction: fraction) }
    }

    // MARK: Sound output

    /// Whether the default sound output is the LG over DisplayPort or HDMI, the links
    /// macOS cannot set the volume of.
    static func lgIsSoundOutput() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
        else { return false }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() as String?
        else { return false }
        return value.uppercased().contains("ULTRAFINE")
    }
}

/// A small level indicator shown on the LG while the volume changes, in place of the
/// macOS one (which only says the output has no volume control).
final class VolumeHUD {
    static let shared = VolumeHUD()

    private var panel: NSPanel?
    private let icon = NSImageView()
    private let bar = NSLevelIndicator()
    private var hide: DispatchWorkItem?

    func show(fraction: Double) {
        let panel = self.panel ?? makePanel()
        let symbol: String
        switch fraction {
        case ..<0.001: symbol = "speaker.slash.fill"
        case ..<0.34: symbol = "speaker.wave.1.fill"
        case ..<0.67: symbol = "speaker.wave.2.fill"
        default: symbol = "speaker.wave.3.fill"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Volume")
        bar.doubleValue = fraction * 100

        let screen = LGMonitor.displayID().flatMap { id in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        } ?? NSScreen.main
        if let frame = screen?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + frame.height / 8))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hide?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { panel?.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 260, height: 52)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        icon.frame = NSRect(x: 14, y: 14, width: 26, height: 24)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .labelColor
        background.addSubview(icon)

        bar.frame = NSRect(x: 50, y: 20, width: size.width - 66, height: 12)
        bar.levelIndicatorStyle = .continuousCapacity
        bar.minValue = 0
        bar.maxValue = 100
        bar.warningValue = 101
        bar.criticalValue = 101
        bar.fillColor = .labelColor
        background.addSubview(bar)

        self.panel = panel
        return panel
    }
}
