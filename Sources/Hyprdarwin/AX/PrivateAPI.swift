// Private SPI that works with SIP enabled. The same calls are used by
// yabai, AeroSpace, Amethyst and HyprMac; hyprdarwin's use follows HyprMac
// (https://github.com/zacharytgray/HyprMac, HyprMac/PrivateAPI/CGSPrivate.h
// and HyprMac/Models/HyprWindow.swift, MIT License, Copyright (c) 2026
// Zachary Gray). See THIRD_PARTY_NOTICES.md.

import ApplicationServices
import CoreGraphics
import Darwin

/// AXUIElement -> CGWindowID. Exported by HIServices.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowID(of element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
    return id
}

/// SkyLight focus calls, resolved at runtime so the binary does not link a
/// private framework. If any symbol is missing the caller falls back to
/// NSRunningApplication.activate.
enum SkyLight {
    private typealias SetFrontProcess = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> CGError
    private typealias PostEventRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)

    private static let setFrontProcess: SetFrontProcess? = symbol(skyLight, "_SLPSSetFrontProcessWithOptions")
    private static let postEventRecord: PostEventRecord? = symbol(skyLight, "SLPSPostEventRecordTo")
    private static let processForPID: ProcessForPID? = symbol(hiServices, "GetProcessForPID")

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let userGenerated: UInt32 = 0x200

    /// Front the owning process with `windowID` as its key window, the way
    /// yabai's window_manager_focus_window does. False when unavailable.
    @discardableResult
    static func makeKeyWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processForPID else { return false }
        // ProcessSerialNumber is two UInt32s
        var psn = [UInt32](repeating: 0, count: 2)
        let found = psn.withUnsafeMutableBytes { processForPID(pid, $0.baseAddress!) }
        guard found == noErr else { return false }
        let front = psn.withUnsafeMutableBytes { setFrontProcess($0.baseAddress!, windowID, userGenerated) }
        guard front == .success else { return false }

        // event record layout from yabai's window_manager_make_key_window
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = 0x01
        bytes[0x3A] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { source in
            for index in 0..<4 { bytes[0x3C + index] = source[index] }
        }
        for index in 0..<0x10 { bytes[0x20 + index] = 0xFF }
        psn.withUnsafeMutableBytes { pointer in
            bytes.withUnsafeMutableBufferPointer { record in
                _ = postEventRecord(pointer.baseAddress!, record.baseAddress!)
                record[0x08] = 0x02
                _ = postEventRecord(pointer.baseAddress!, record.baseAddress!)
            }
        }
        return true
    }
}
