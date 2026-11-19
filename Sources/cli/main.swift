// lgpbp — command-line PBP control for the LG UltraFine 40U990A.
//
//   lgpbp state         PBP state inferred from the Mac's picture (sends nothing to the monitor)
//   lgpbp status        ask the monitor (one read of code 0xD7); also detects PIP
//   lgpbp on [50|75] [--left usbc|dp|hdmi1]
//                       PBP 50/50 (default) or 75/25; with --left, first switch to that
//                       input so it ends up on the left (only when PBP is off)
//   lgpbp off           leave PBP or PIP
//   lgpbp input         ask the monitor which input is shown (one read of code 0x60)
//   lgpbp input <name>  switch input: usbc, dp, hdmi1 or hdmi2 (LG code 0xF4 on address 0x50)
//   lgpbp volume        ask the monitor for its speaker volume (one read of code 0x62)
//   lgpbp volume <n>    set the speaker volume (code 0x62), capped at 100

import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func send(_ mode: PBPMode) {
    do {
        let bytes = try LGMonitor.setPBP(mode)
        print("\(mode.label): sent \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    } catch { fail("\(error)") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "state":
    guard let mode = LGMonitor.inferredMode() else { fail("\(LGError.notConnected)") }
    print(mode.label)
case "status":
    do {
        guard let v = try LGMonitor.readPBP() else { fail("No valid reply from the monitor (it may be switching modes; try again)") }
        let label = v == 0 ? "PIP active" : (PBPMode(rawValue: v)?.label ?? "unknown value")
        print("PBP (D7) = \(v): \(label)")
    } catch { fail("\(error)") }
case "on":
    let usage = "usage: lgpbp on [50|75] [--left \(LGInput.allCases.filter(\.switchConfirmed).map(\.argument).joined(separator: "|"))]"
    var rest = Array(args.dropFirst())
    var left: LGInput?
    if let i = rest.firstIndex(of: "--left") {
        guard i + 1 < rest.count,
              let input = LGInput.allCases.first(where: { $0.argument == rest[i + 1] && $0.switchConfirmed })
        else { fail(usage) }
        left = input
        rest.removeSubrange(i...(i + 1))
    }
    let mode: PBPMode
    switch rest.first ?? "50" {
    case "50": mode = .half
    case "75": mode = .wide
    default: fail(usage)
    }
    guard rest.count <= 1 else { fail(usage) }
    // Switching inputs is only for starting PBP; changing between 50/50 and 75/25 keeps the sides.
    // Ask the monitor whether PBP is off (the picture's shape can be wrong over some links).
    if let left, ((try? LGMonitor.readMode()) ?? LGMonitor.inferredMode()) == .off {
        do {
            let sent = try LGMonitor.startPBP(mode, left: left)
            print("\(left.label) on the left: sent on 0x50: \(sent[0].map { String(format: "%02X", $0) }.joined(separator: " "))")
            print("\(mode.label): sent \(sent[1].map { String(format: "%02X", $0) }.joined(separator: " "))")
        } catch { fail("\(error)") }
    } else {
        if left != nil { print("PBP is already on; keeping the current sides") }
        send(mode)
    }
case "off":
    send(.off)
case "input" where args.count == 1:
    do {
        guard let v = try LGMonitor.readInput() else { fail("No valid reply from the monitor (try again)") }
        let label = LGInput(rawValue: v & 0xFF)?.label ?? "unknown value"
        print("Input (60) = \(v): \(label)")
    } catch { fail("\(error)") }
case "input" where args.count == 2:
    let value: UInt8
    let label: String
    if let input = LGInput.allCases.first(where: { $0.argument == args[1] }) {
        value = input.switchValue
        label = input.label
    } else {
        fail("usage: lgpbp input [usbc|dp|hdmi1|hdmi2]")
    }
    do {
        let bytes = try LGMonitor.switchInput(value: value)
        print("\(label): sent on 0x50: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    } catch { fail("\(error)") }
case "volume" where args.count == 1:
    do {
        guard let v = try LGMonitor.readVolume() else { fail("No valid reply from the monitor (try again)") }
        print("Volume (62) = \(v.level) of \(v.max)")
    } catch { fail("\(error)") }
case "volume" where args.count == 2:
    guard let level = UInt16(args[1]), level <= LGMonitor.volumeCap else { fail("usage: lgpbp volume [0-\(LGMonitor.volumeCap)]") }
    do {
        let bytes = try LGMonitor.setVolume(level)
        print("Volume \(level): sent \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    } catch { fail("\(error)") }
default:
    print("usage: lgpbp state | status | on [50|75] [--left usbc|dp|hdmi1] | off | input [usbc|dp|hdmi1|hdmi2] | volume [0-100]")
}
