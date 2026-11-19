// Tells one local network from another, to notice that the Mac has left the place
// where the iPad is.
//
// macOS identifies each network by its router (address and hardware address) and
// publishes that as a "network signature", readable without the Location permission a
// Wi-Fi name would need. Only Ethernet and Wi-Fi interfaces count, so turning a VPN on
// does not look like a move.

import Foundation
import Network
import SystemConfiguration

enum NetworkIdentity {
    /// The signatures of the networks this Mac is on now; empty when it is on none.
    static func current() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "lgpbp" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] else { return [] }
        var found = Set<String>()
        for key in keys {
            guard let entry = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = entry["InterfaceName"] as? String, interface.hasPrefix("en"),
                  let signature = entry["NetworkSignature"] as? String else { continue }
            found.insert(signature)
        }
        return found
    }

    private static let monitor = NWPathMonitor()

    /// Calls `handler` on the main queue whenever the network changes.
    static func onChange(_ handler: @escaping () -> Void) {
        monitor.pathUpdateHandler = { _ in DispatchQueue.main.async(execute: handler) }
        monitor.start(queue: DispatchQueue(label: "lgpbp.network"))
    }
}
