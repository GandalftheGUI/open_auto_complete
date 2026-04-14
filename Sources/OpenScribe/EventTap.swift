import Cocoa

enum EventTapError: LocalizedError {
    case createFailed
    var errorDescription: String? {
        switch self {
        case .createFailed:
            return "CGEvent.tapCreate returned nil — Input Monitoring permission likely missing."
        }
    }
}

/// Holds an installed CGEventTap. Releases on deinit.
final class EventTap {

    private let machPort: CFMachPort
    private let runLoopSource: CFRunLoopSource
    private let onEvent: (CGEventType, CGEvent) -> Void

    /// Installs a session-wide listener for the given event types. The callback runs on
    /// the main run loop. `listenOnly` means we cannot modify or swallow events.
    static func installListenOnly(
        events: [CGEventType],
        _ onEvent: @escaping (CGEventType, CGEvent) -> Void
    ) throws -> EventTap {
        var mask: CGEventMask = 0
        for type in events { mask |= (1 << type.rawValue) }

        // Trampoline so we can capture the Swift closure across the C ABI.
        final class Box {
            let cb: (CGEventType, CGEvent) -> Void
            init(_ cb: @escaping (CGEventType, CGEvent) -> Void) { self.cb = cb }
        }
        let box = Box(onEvent)
        let userInfo = Unmanaged.passRetained(box).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info = info {
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                box.cb(type, event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            Unmanaged<Box>.fromOpaque(userInfo).release()
            throw EventTapError.createFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return EventTap(machPort: tap, runLoopSource: source, onEvent: onEvent)
    }

    private init(machPort: CFMachPort, runLoopSource: CFRunLoopSource, onEvent: @escaping (CGEventType, CGEvent) -> Void) {
        self.machPort = machPort
        self.runLoopSource = runLoopSource
        self.onEvent = onEvent
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CFMachPortInvalidate(machPort)
    }
}
