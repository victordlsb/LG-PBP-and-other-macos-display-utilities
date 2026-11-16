// Link between the copies of the app on the two Macs, over the local network.
//
// Two things need it:
//   - A Mac with its lid closed lets its picture go to sleep. The monitor then finds no
//     signal on that input and falls back to the other one a few seconds later. The
//     input switch itself does not wake that Mac (the monitor keeps the link to an
//     input it is not showing), so the Mac that sends the switch first asks the other
//     one to wake its picture, and waits for the answer instead of a fixed delay.
//   - The monitor cannot say which input it shows, so each Mac tells the other when it
//     puts an input full screen; the ⌃⌥⌘O toggle then also knows about changes made
//     from the other Mac.
//
// The apps find each other with Bonjour ("_lgpbp._tcp") and exchange one text line per
// connection: "wake" -> "awake" | "asleep", and "shown <input value>" -> "ok". Nothing
// else is accepted. Without an answer the switch is sent anyway, as before.

import AppKit
import IOKit.pwr_mgt
import Network

final class Peer {
    static let shared = Peer()

    /// Called on the main queue when the other Mac reports the input it put full screen.
    var onShown: ((LGInput) -> Void)?

    private let type = "_lgpbp._tcp"
    private let name = "LG PBP \(UUID().uuidString)"   // unique per launch, to leave out this Mac
    private let queue = DispatchQueue(label: "lgpbp.peer")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    private var activity: IOPMAssertionID = 0

    /// Whether the other Mac's copy of the app is in reach.
    var isLinked: Bool { queue.sync { !endpoints.isEmpty } }

    func start() {
        if let listener = try? NWListener(using: .tcp) {
            listener.service = NWListener.Service(name: name, type: type)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
            self.listener = listener
        }
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.endpoints = results.map(\.endpoint).filter {
                if case .service(let found, _, _, _) = $0 { return found != self.name }
                return false
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: Asking the other Mac

    /// Asks the other Mac to wake its picture and waits until it says it is awake.
    /// Returns "awake", "asleep" (it did not wake in time) or nil (no answer).
    /// Blocks; never call it on the main queue.
    func wakeOtherMac(timeout: TimeInterval = 7) -> String? {
        guard let endpoint = queue.sync(execute: { endpoints.first }) else { return nil }
        return request("wake", to: endpoint, timeout: timeout)
    }

    /// Tells the other Mac which input was just put full screen.
    func announce(shown input: LGInput) {
        let targets = queue.sync { endpoints }
        DispatchQueue.global().async {
            for endpoint in targets { _ = self.request("shown \(input.rawValue)", to: endpoint, timeout: 2) }
        }
    }

    private func request(_ line: String, to endpoint: NWEndpoint, timeout: TimeInterval) -> String? {
        let done = DispatchSemaphore(value: 0)
        var reply: String?
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                    reply = data.flatMap { String(data: $0, encoding: .utf8) }?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    done.signal()
                }
            case .failed, .cancelled:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        let answer = queue.sync { reply }
        connection.cancel()
        return answer
    }

    // MARK: Answering the other Mac

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            let answer: (String) -> Void = { reply in
                connection.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            if words == ["wake"] {
                DispatchQueue.global().async { answer(self.wakePicture() ? "awake" : "asleep") }
            } else if words.count == 2, words[0] == "shown", let value = UInt16(words[1]),
                      let input = LGInput(rawValue: value), LGInput.inUse.contains(input) {
                DispatchQueue.main.async { self.onShown?(input) }
                answer("ok")
            } else {
                connection.cancel()
            }
        }
    }

    /// Wakes this Mac's picture, the way a key press would, and waits until it is on.
    private func wakePicture() -> Bool {
        IOPMAssertionDeclareUserActivity("LG PBP: the other Mac is switching the monitor to this one" as CFString,
                                         kIOPMUserActiveLocal, &activity)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let display = LGMonitor.displayID() ?? CGMainDisplayID()
            if CGDisplayIsAsleep(display) == 0 { return true }
            usleep(100_000)
        }
        return false
    }
}
