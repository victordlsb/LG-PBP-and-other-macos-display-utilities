// Shared monitor access for the LG UltraFine 40U990A (Apple Silicon).
//
// Everything sent to the monitor goes through this file, and it is limited to:
//   - 0xD7 (PBP) and 0x60 (read the input), on the standard DDC address 0x51;
//   - 0xF4 (switch input), on LG's alternate address 0x50, with a fixed list of values.
// 0x50 is LG's service channel. A sweep of it during development damaged the monitor's
// settings, so nothing else may ever be sent there: no other code, no reads, no scans.
//
// Values of 0xD7 verified on this monitor:
//   1 = off (also exits PIP)   3 = PBP 75/25 (3840 + 1280)   5 = PBP 50/50 (2560 + 2560)
//   0 = reported while PIP is active; ignored as a command.   2 and 4 are ignored.

import Foundation
import IOKit
import CoreGraphics

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                        _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

enum PBPMode: UInt16 {
    case off = 1, wide = 3, half = 5

    var label: String {
        switch self {
        case .off: return "Off"
        case .wide: return "PBP 75/25"
        case .half: return "PBP 50/50"
        }
    }
}

/// The monitor's inputs.
///
/// `rawValue` is what the standard input-source code (0x60) reads back. The standard
/// names do not match this monitor's ports: its USB-C / Thunderbolt input reads 0x0F,
/// which the standard calls DisplayPort 1. Writing 0x60 is ignored by this monitor.
///
/// `switchValue` is what LG's own input-switch code (0xF4 on address 0x50) takes.
/// HDMI 1 (0x90) and USB-C (0xD2) are confirmed on the 40U990A; the others come
/// from notes on other LG models. 0xD1, used for USB-C on some models, does nothing here.
enum LGInput: UInt16, CaseIterable {
    case usbC = 0x0F, displayPort = 0x10, hdmi1 = 0x11, hdmi2 = 0x12

    var label: String {
        switch self {
        case .usbC: return "USB-C / Thunderbolt"
        case .displayPort: return "DisplayPort"
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        }
    }

    /// Name used on the command line.
    var argument: String {
        switch self {
        case .usbC: return "usbc"
        case .displayPort: return "dp"
        case .hdmi1: return "hdmi1"
        case .hdmi2: return "hdmi2"
        }
    }

    var switchValue: UInt8 {
        switch self {
        case .usbC: return 0xD2          // confirmed (0xD1 does nothing on this model)
        case .displayPort: return 0xD0   // unconfirmed
        case .hdmi1: return 0x90         // confirmed
        case .hdmi2: return 0x91         // unconfirmed
        }
    }

    /// Whether `switchValue` has been seen to work on the 40U990A. Only confirmed
    /// inputs are offered as the PBP left side.
    var switchConfirmed: Bool { self == .hdmi1 || self == .usbC }
}

enum LGError: Error, CustomStringConvertible {
    case notConnected
    case ambiguous(Int)
    case i2c(String)

    var description: String {
        switch self {
        case .notConnected: return "LG UltraFine 40U990A not connected"
        case .ambiguous(let n): return "Expected one external display service, found \(n)"
        case .i2c(let what): return "Monitor communication failed (\(what))"
        }
    }
}

enum LGMonitor {
    // EDID identity of the 40U990A. Commands are refused for any other display,
    // because 0xD7 means something else on other monitors.
    // The model number depends on the input: 0x9EBA over USB-C / Thunderbolt,
    // 0x9EB8 over HDMI 1 (seen through a USB-C to HDMI adapter).
    static let vendor: UInt32 = 0x1E6D
    static let models: Set<UInt32> = [0x9EBA, 0x9EB8]

    private static let chip: UInt32 = 0x37     // DDC/CI I2C address
    private static let host: UInt8 = 0x51      // standard host source address
    private static let pbpCode: UInt8 = 0xD7
    private static let inputCode: UInt8 = 0x60
    private static let altHost: UInt8 = 0x50          // LG service channel: input switching only
    private static let inputSwitchCode: UInt8 = 0xF4
    /// The only values that may be sent on the service channel.
    static let allowedSwitchValues: Set<UInt8> = [0x90, 0x91, 0xD0, 0xD1, 0xD2]

    static func displayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first {
            CGDisplayVendorNumber($0) == vendor && models.contains(CGDisplayModelNumber($0))
        }
    }

    /// The input this Mac is connected to, from the model number in the EDID (it differs
    /// per input). Sends nothing to the monitor. Nil when not connected or not recognised.
    static func ownInput() -> LGInput? {
        guard let id = displayID() else { return nil }
        switch CGDisplayModelNumber(id) {
        case 0x9EBA: return .usbC
        case 0x9EB8: return .hdmi1
        default: return nil
        }
    }

    /// PBP state inferred from the shape of the picture the Mac is sending. Sends nothing
    /// to the monitor. PIP cannot be seen this way (the Mac keeps the full panel), so it
    /// shows as `.off`. Returns nil when the monitor is not connected.
    static func inferredMode() -> PBPMode? {
        guard let id = displayID(), let mode = CGDisplayCopyDisplayMode(id), mode.pixelHeight > 0 else { return nil }
        let aspect = Double(mode.pixelWidth) / Double(mode.pixelHeight)
        if aspect > 2.1 { return .off }      // 5120 x 2160 = 2.37
        if aspect > 1.5 { return .wide }     // 3840 x 2160 = 1.78
        return .half                         // 2560 x 2160 = 1.19
    }

    private static func service() throws -> CFTypeRef {
        guard displayID() != nil else { throw LGError.notConnected }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else {
            throw LGError.i2c("no display services")
        }
        defer { IOObjectRelease(iter) }
        var found: [CFTypeRef] = []
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard loc == "External" else { continue }
            if let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() { found.append(svc) }
        }
        // With more than one external display we cannot tell which service is the LG, so refuse.
        guard found.count == 1 else { throw LGError.ambiguous(found.count) }
        return found[0]
    }

    private static func checksummed(_ body: [UInt8]) -> [UInt8] {
        var chk: UInt8 = 0x6E ^ host
        for b in body { chk ^= b }
        return body + [chk]
    }

    /// Set VCP 0xD7. Returns the bytes sent.
    @discardableResult
    static func setPBP(_ mode: PBPMode) throws -> [UInt8] {
        try setVCP(pbpCode, mode.rawValue)
    }

    /// The PBP state as the monitor reports it (one read of 0xD7). PIP counts as off,
    /// since "off" is also what exits it. Returns nil when the monitor gives no valid
    /// answer, which happens for a few seconds after a mode switch.
    static func readMode() throws -> PBPMode? {
        guard let v = try readPBP() else { return nil }
        return v == 0 ? .off : PBPMode(rawValue: v)
    }

    /// Seconds to wait after an input switch before the monitor takes the next command.
    static let switchSettle: TimeInterval = 4

    /// Turn PBP on with `left` on the left side.
    ///
    /// The monitor puts the input that is on screen when PBP starts on the left (the
    /// large part in 75/25), and no command for swapping the sides is known. So this
    /// first switches to `left`, waits, and then turns PBP on; 0xD7 is accepted even
    /// from the input that is no longer on screen. Only call it while PBP is off:
    /// what an input switch does during PBP is untested. Returns the bytes of both
    /// commands.
    @discardableResult
    static func startPBP(_ mode: PBPMode, left: LGInput) throws -> [[UInt8]] {
        guard mode != .off, left.switchConfirmed else { throw LGError.i2c("PBP left side not allowed") }
        let switched = try switchInput(value: left.switchValue)
        Thread.sleep(forTimeInterval: switchSettle)
        return [switched, try setPBP(mode)]
    }

    /// Show `input` full screen: turn PBP off first if it is on (`pbpOn`), wait for the
    /// monitor to settle, then switch input. The switch is never sent while PBP is on,
    /// because what it does then is untested. Returns the bytes of each command sent.
    @discardableResult
    static func showFullScreen(_ input: LGInput, pbpOn: Bool) throws -> [[UInt8]] {
        guard input.switchConfirmed else { throw LGError.i2c("input not allowed") }
        var sent: [[UInt8]] = []
        if pbpOn {
            sent.append(try setPBP(.off))
            Thread.sleep(forTimeInterval: 3)
        }
        sent.append(try switchInput(value: input.switchValue))
        return sent
    }

    /// Get VCP 0xD7 from the monitor. Returns nil if it gave no valid answer, which
    /// happens for a few seconds while it is switching modes.
    static func readPBP() throws -> UInt16? {
        try readVCP(pbpCode)
    }

    /// Switch the monitor's input with LG's own code (0xF4 on address 0x50).
    /// Refuses any value outside the fixed list. Returns the bytes sent.
    @discardableResult
    static func switchInput(value: UInt8) throws -> [UInt8] {
        guard allowedSwitchValues.contains(value) else { throw LGError.i2c("input value not allowed") }
        let svc = try service()
        let body: [UInt8] = [0x84, 0x03, inputSwitchCode, 0x00, value]
        var chk: UInt8 = 0x6E ^ altHost
        for b in body { chk ^= b }
        var packet = body + [chk]
        for _ in 0..<2 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(svc, chip, UInt32(altHost), &packet, UInt32(packet.count)) == KERN_SUCCESS else {
                throw LGError.i2c("write")
            }
        }
        return packet
    }

    /// Get VCP 0x60. Returns nil if the monitor gave no valid answer.
    static func readInput() throws -> UInt16? {
        try readVCP(inputCode)
    }

    private static func setVCP(_ code: UInt8, _ value: UInt16) throws -> [UInt8] {
        let svc = try service()
        var packet = checksummed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
        for _ in 0..<3 {   // LG's helper sends a set three times
            usleep(10_000)
            guard IOAVServiceWriteI2C(svc, chip, UInt32(host), &packet, UInt32(packet.count)) == KERN_SUCCESS else {
                throw LGError.i2c("write")
            }
        }
        return packet
    }

    private static func readVCP(_ code: UInt8) throws -> UInt16? {
        let svc = try service()
        var packet = checksummed([0x82, 0x01, code])
        for _ in 0..<3 {
            for _ in 0..<2 {   // the monitor only answers when the request is sent twice
                usleep(10_000)
                guard IOAVServiceWriteI2C(svc, chip, UInt32(host), &packet, UInt32(packet.count)) == KERN_SUCCESS else {
                    throw LGError.i2c("write")
                }
            }
            usleep(50_000)
            var r = [UInt8](repeating: 0, count: 11)
            guard IOAVServiceReadI2C(svc, chip, UInt32(host), &r, 11) == KERN_SUCCESS else { throw LGError.i2c("read") }
            // [6E 88 02 result code type maxH maxL curH curL chk]
            var chk: UInt8 = 0x50
            for b in r[0..<10] { chk ^= b }
            if r[2] == 0x02, r[3] == 0, r[4] == code, chk == r[10] {
                return UInt16(r[8]) << 8 | UInt16(r[9])
            }
            usleep(100_000)
        }
        return nil
    }
}
