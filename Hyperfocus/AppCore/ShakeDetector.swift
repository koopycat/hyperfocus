import Cocoa

/// Detects rapid mouse shake gestures to toggle focus mode.
/// Works via CGEvent tap for low-latency mouse velocity tracking.
final class ShakeDetector {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Mouse positions over the last ~300ms
    private var positionHistory: [(time: TimeInterval, point: CGPoint)] = []

    /// Minimum velocity in points/second to count as a shake
    var sensitivity: CGFloat = 3000

    /// Number of direction reversals needed to trigger
    private let requiredReversals = 3
    private var recentDirections: [CGFloat] = [] // positive = right, negative = left

    var onShakeDetected: (() -> Void)?

    // MARK: - Start / Stop

    func start() {
        guard eventTap == nil else { return }

        let eventMask = (1 << CGEventType.mouseMoved.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: shakeDetectorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            print("[Hyperfocus] Failed to create CGEvent tap for shake detection")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        positionHistory.removeAll()
        recentDirections.removeAll()
    }

    // MARK: - Detection Logic

    func processMouseMove(at point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime

        // Maintain sliding window
        positionHistory.append((time: now, point: point))
        positionHistory = positionHistory.filter { now - $0.time < 0.3 }

        guard positionHistory.count >= 3 else { return }

        // Calculate velocities between consecutive points
        var velocities: [CGFloat] = []
        for i in 1..<positionHistory.count {
            let prev = positionHistory[i - 1]
            let curr = positionHistory[i]
            let dt = curr.time - prev.time
            guard dt > 0 else { continue }
            let dx = curr.point.x - prev.point.x
            let v = dx / CGFloat(dt)
            velocities.append(v)
        }

        // Check for rapid direction reversals
        recentDirections = velocities
        let reversals = countReversals(in: velocities)

        if reversals >= requiredReversals {
            // Check if any velocity exceeds threshold
            let maxVelocity = velocities.map { abs($0) }.max() ?? 0
            if maxVelocity >= sensitivity {
                onShakeDetected?()
                // Reset to prevent double-fires
                positionHistory.removeAll()
                recentDirections.removeAll()
            }
        }
    }

    private func countReversals(in velocities: [CGFloat]) -> Int {
        var count = 0
        guard velocities.count >= 2 else { return 0 }

        var lastSign: CGFloat = velocities[0] >= 0 ? 1 : -1
        for i in 1..<velocities.count {
            let sign: CGFloat = velocities[i] >= 0 ? 1 : -1
            if sign != lastSign {
                count += 1
                lastSign = sign
            }
        }
        return count
    }
}

// MARK: - CGEvent Callback

private func shakeDetectorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .mouseMoved, let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    let detector = Unmanaged<ShakeDetector>.fromOpaque(refcon).takeUnretainedValue()
    detector.processMouseMove(at: event.location)

    return Unmanaged.passUnretained(event)
}
