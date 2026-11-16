// Reverses the scroll direction of mouse wheels while leaving the trackpad alone.
//
// macOS has a single "natural scrolling" setting for both. This keeps it on (for the
// trackpad) and flips only the wheel events. A wheel sends discrete line steps, a
// trackpad (or Magic Mouse) sends continuous scrolling, so the test is the event's
// "continuous" flag rather than which device it came from. That also covers a mouse
// borrowed from another Mac through Universal Control, which arrives as a virtual device.
//
// Needs the Accessibility permission, like window snapping. Nothing here talks to the monitor.

import AppKit

final class ScrollReverser {
    static let shared = ScrollReverser()

    /// Stored per Mac: turn it on only on the Mac whose mouse is not already reversed.
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "reverseMouseWheel") }
        set {
            UserDefaults.standard.set(newValue, forKey: "reverseMouseWheel")
            update()
        }
    }

    /// True while the event tap is installed and reversing wheel events.
    var active: Bool { tap != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?

    func start() { update() }

    private func update() {
        if enabled { install() } else { remove() }
    }

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = ScrollReverser.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .scrollWheel, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
                ScrollReverser.flip(event)
            }
            return Unmanaged.passUnretained(event)
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

    /// Negates every delta field, vertical and horizontal, so apps reading any of them agree.
    private static func flip(_ event: CGEvent) {
        let integerFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                                             .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
        let fixedFields: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
        // Read everything first: setting one field can recompute the others.
        let ints = integerFields.map { event.getIntegerValueField($0) }
        let fixed = fixedFields.map { event.getDoubleValueField($0) }
        for (field, value) in zip(integerFields, ints) { event.setIntegerValueField(field, value: -value) }
        for (field, value) in zip(fixedFields, fixed) { event.setDoubleValueField(field, value: -value) }
    }
}
