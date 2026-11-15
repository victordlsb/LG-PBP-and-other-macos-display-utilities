// lgpbp — command-line PBP control for the LG UltraFine 40U990A.
//
//   lgpbp state         PBP state inferred from the Mac's picture (sends nothing to the monitor)
//   lgpbp status        ask the monitor (one read of code 0xD7); also detects PIP
//   lgpbp on [50|75]    PBP 50/50 (default) or 75/25
//   lgpbp off           leave PBP or PIP
//   lgpbp input         ask the monitor which input is shown (one read of code 0x60)
//   lgpbp input <name>  switch input: usbc, dp, hdmi1 or hdmi2 (experimental)

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
    switch args.count > 1 ? args[1] : "50" {
    case "50": send(.half)
    case "75": send(.wide)
    default: fail("usage: lgpbp on [50|75]")
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
    guard let input = LGInput.allCases.first(where: { $0.argument == args[1] }) else {
        fail("usage: lgpbp input [usbc|dp|hdmi1|hdmi2]")
    }
    do {
        let bytes = try LGMonitor.setInput(input)
        print("\(input.label): sent \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    } catch { fail("\(error)") }
default:
    print("usage: lgpbp state | status | on [50|75] | off | input [usbc|dp|hdmi1|hdmi2]")
}
