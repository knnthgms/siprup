import CoreMotion
import Foundation

/// Reads device gravity and exposes the angle the liquid surface should take on screen.
/// Not observable on purpose: the liquid canvas polls it every frame, so publishing
/// changes would only cause needless SwiftUI invalidations.
final class TiltSensor {
    private let manager = CMMotionManager()

    /// Radians. Positive when the phone's right edge dips, which raises the liquid on the right.
    private(set) var angle: Double = 0

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            // Upright portrait: gravity ≈ (0, -1). Ignore near-flat orientations where x/y are tiny.
            let planar = sqrt(g.x * g.x + g.y * g.y)
            guard planar > 0.2 else { return }
            let raw = atan2(g.x, -g.y)
            self?.angle = min(max(raw, -0.7), 0.7)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        angle = 0
    }
}
