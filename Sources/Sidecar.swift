// Connects an iPad as an extended display (Sidecar).
//
// macOS has no public interface for this, so it goes through the private
// SidecarCore framework by name. Every call is checked with responds(to:) first,
// so if Apple changes the framework the feature turns itself off instead of crashing.

import Foundation

enum Sidecar {
    private static let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil,
              let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedManager")) else { return nil }
        return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
    }()

    private static func list(_ selector: String) -> [NSObject] {
        let sel = NSSelectorFromString(selector)
        guard let manager, manager.responds(to: sel) else { return [] }
        return manager.perform(sel)?.takeUnretainedValue() as? [NSObject] ?? []
    }

    /// iPads currently in reach.
    static var devices: [NSObject] { list("devices") }

    static func name(of device: NSObject) -> String {
        let sel = NSSelectorFromString("name")
        guard device.responds(to: sel) else { return "iPad" }
        return device.perform(sel)?.takeUnretainedValue() as? String ?? "iPad"
    }

    static func isConnected(_ device: NSObject) -> Bool {
        let wanted = name(of: device)
        return list("connectedDevices").contains { $0.isEqual(device) || name(of: $0) == wanted }
    }

    /// iPads currently connected as displays, in reach or not.
    static var connectedDevices: [NSObject] { list("connectedDevices") }

    /// Names of the iPads currently connected as displays.
    static var connectedNames: Set<String> { Set(list("connectedDevices").map(name(of:))) }

    /// Connects or disconnects the iPad. `completion` receives an error message, or nil on success,
    /// on the main queue.
    static func setConnected(_ device: NSObject, _ connect: Bool, completion: @escaping (String?) -> Void) {
        let sel = NSSelectorFromString(connect ? "connectToDevice:completion:" : "disconnectFromDevice:completion:")
        guard let manager, manager.responds(to: sel) else {
            completion("this macOS version no longer supports it")
            return
        }
        let done: @convention(block) (NSError?) -> Void = { error in
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
        manager.perform(sel, with: device, with: done)
    }
}
