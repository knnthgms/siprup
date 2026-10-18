import SwiftUI

/// One visual band in the glass: a single logged drink. Bands stack in the order drinks were logged.
struct LiquidLayer: Identifiable, Equatable {
    let id: String
    let name: String
    let colorHex: String
    let time: Date
    var volumeML: Double
    let isFizzy: Bool
    let hasFoam: Bool

    var color: Color { Color(hex: colorHex) }
}

/// Shared geometry so the canvas and the SwiftUI labels agree on where layers sit.
enum GlassGeometry {
    /// Fraction of screen height the liquid reaches when the goal is met.
    static let goalFraction = 0.84

    /// Hex colour of whatever sits behind screen point `y` (a band, or the empty glass).
    static func backgroundHex(atY y: Double, layers: [LiquidLayer], height: Double, goalML: Double, emptyHex: String) -> String {
        let bands = self.bands(volumes: layers.map(\.volumeML), height: height, goalML: goalML)
        for (i, band) in bands.enumerated() where y >= band.top && y <= band.bottom {
            return layers[i].colorHex
        }
        return emptyHex
    }

    static func scale(height: Double, goalML: Double, totalML: Double) -> Double {
        (height * goalFraction) / max(goalML, totalML, 1)
    }

    /// (top, bottom) y-coordinates at the screen's horizontal centre, bottom layer first.
    static func bands(volumes: [Double], height: Double, goalML: Double) -> [(top: Double, bottom: Double)] {
        let s = scale(height: height, goalML: goalML, totalML: volumes.reduce(0, +))
        var y = height
        return volumes.map { v in
            let bottom = y
            y -= v * s
            return (y, bottom)
        }
    }
}

/// Mutable per-frame state: sloshing angle and smoothly rising volumes.
final class LiquidSim {
    var angle: Double = 0
    var angularVelocity: Double = 0
    var energy: Double = 0
    var displayed: [String: Double] = [:]
    private var lastTime: Double?

    func step(time: Double, targetAngle: Double, targets: [LiquidLayer], animate: Bool) {
        guard animate else {
            angle = 0; angularVelocity = 0; energy = 0; lastTime = nil
            displayed = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.volumeML) })
            return
        }
        let dt = lastTime.map { min(max(time - $0, 0), 1.0 / 20) } ?? 0
        lastTime = time

        // Damped spring toward the gravity angle gives a little overshoot = slosh.
        let accel = (targetAngle - angle) * 28 - angularVelocity * 4.2
        angularVelocity += accel * dt
        angle += angularVelocity * dt

        var pouring = false
        var next: [String: Double] = [:]
        for layer in targets {
            let current = displayed[layer.id] ?? 0
            let diff = layer.volumeML - current
            if diff > 1 { pouring = true }
            next[layer.id] = abs(diff) < 0.5 ? layer.volumeML : current + diff * min(1, dt * 2.5)
        }
        displayed = next

        energy *= exp(-dt * 1.1)
        if pouring { energy = min(1, energy + dt * 2.5) }
        energy = min(1, energy + abs(angularVelocity) * dt * 0.8)
    }
}

/// The whole screen as the side of a glass. Purely illustrative — it draws logged drinks,
/// it does not measure anything, and stacked bands are not how drinks mix in the body.
struct LiquidGlassView: View {
    let layers: [LiquidLayer]
    let goalML: Double
    let reduceMotion: Bool
    let tilt: TiltSensor

    @State private var sim = LiquidSim()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                sim.step(time: t, targetAngle: reduceMotion ? 0 : tilt.angle, targets: layers, animate: !reduceMotion)
                drawGlass(&ctx, size: size)
                drawLiquid(&ctx, size: size, t: reduceMotion ? 0 : t)
            }
        }
        .overlay { GlassHighlights().allowsHitTesting(false) }
        .background(colorScheme == .dark ? Color(hex: "0E151C") : Color(hex: "E9F1F6"))
    }

    // MARK: Drawing

    private func drawGlass(_ ctx: inout GraphicsContext, size: CGSize) {
        let dark = colorScheme == .dark
        let colors = dark
            ? [Color(hex: "16212B"), Color(hex: "0E151C")]
            : [Color(hex: "F4F8FB"), Color(hex: "DCE7EE")]
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func drawLiquid(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let volumes = layers.map { sim.displayed[$0.id] ?? 0 }
        guard volumes.reduce(0, +) > 0.5 else { return }

        let bands = GlassGeometry.bands(volumes: volumes, height: h, goalML: goalML)
        let slope = tan(sim.angle)
        let cx = w / 2
        let amp = reduceMotion ? 0 : 2.5 + 9 * sim.energy + min(abs(sim.angularVelocity) * 10, 10)

        func surface(_ baseY: Double, _ x: Double, waveScale: Double) -> Double {
            let k = x / w * 2 * .pi
            let wave = sin(k * 1.3 + t * 1.7) + 0.5 * sin(k * 2.9 - t * 2.4)
            return baseY - slope * (x - cx) + waveScale * amp * wave
        }

        func band(top: Double, bottom: Double?, topWave: Double, bottomWave: Double) -> Path {
            var p = Path()
            let xs = Array(stride(from: -12.0, through: w + 12, by: 6))
            p.move(to: CGPoint(x: xs[0], y: surface(top, xs[0], waveScale: topWave)))
            for x in xs.dropFirst() { p.addLine(to: CGPoint(x: x, y: surface(top, x, waveScale: topWave))) }
            if let bottom {
                for x in xs.reversed() { p.addLine(to: CGPoint(x: x, y: surface(bottom, x, waveScale: bottomWave))) }
            } else {
                p.addLine(to: CGPoint(x: w + 12, y: h + 200))
                p.addLine(to: CGPoint(x: -12, y: h + 200))
            }
            p.closeSubpath()
            return p
        }

        let topIndex = layers.indices.last { volumes[$0] > 0.5 } ?? 0

        for (i, layer) in layers.enumerated() where volumes[i] > 0.5 {
            let isTop = i == topIndex
            let topWave = isTop ? 1.0 : 0.22
            let bottomWave = i == 0 ? 0 : 0.22
            let path = band(top: bands[i].top, bottom: i == 0 ? nil : bands[i].bottom,
                            topWave: topWave, bottomWave: bottomWave)
            let c = layer.color
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [c.shaded(0.12), c, c.shaded(-0.12)]),
                startPoint: CGPoint(x: 0, y: bands[i].top - 30),
                endPoint: CGPoint(x: 0, y: max(bands[i].bottom, bands[i].top + 60))))

            // Bubbles, clipped to their own band.
            var bubbleCtx = ctx
            bubbleCtx.clip(to: path)
            drawBubbles(&bubbleCtx, layerIndex: i, isFizzy: layer.isFizzy,
                        top: bands[i].top, bottom: i == 0 ? h : bands[i].bottom, width: w, t: t)

            // Glossy sheen just under each band's surface.
            let glossTop = bands[i].top - amp - 20
            bubbleCtx.fill(Path(CGRect(x: 0, y: glossTop, width: w, height: 56 + amp)),
                           with: .linearGradient(
                               Gradient(stops: [
                                   .init(color: .white.opacity(0.0), location: 0),
                                   .init(color: .white.opacity(0.30), location: 0.4),
                                   .init(color: .white.opacity(0.0), location: 1),
                               ]),
                               startPoint: CGPoint(x: 0, y: glossTop),
                               endPoint: CGPoint(x: 0, y: glossTop + 56 + amp)))

            // Soft seam between layers.
            var seam = Path()
            for (j, x) in stride(from: -12.0, through: w + 12, by: 6).enumerated() {
                let pt = CGPoint(x: x, y: surface(bands[i].top, x, waveScale: topWave))
                if j == 0 { seam.move(to: pt) } else { seam.addLine(to: pt) }
            }
            if isTop {
                ctx.stroke(seam, with: .color(.white.opacity(0.18)), lineWidth: 10)
                ctx.stroke(seam, with: .color(.white.opacity(0.7)), lineWidth: 2)
                if layer.hasFoam {
                    drawFoam(&ctx, seam: seam, surface: { surface(bands[i].top, $0, waveScale: 1) }, width: w, t: t)
                }
            } else {
                ctx.stroke(seam, with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
        }

        // Light rays slanting down through the whole liquid, drifting slowly.
        let liquid = band(top: bands[topIndex].top, bottom: nil, topWave: 1, bottomWave: 0)
        var rays = ctx
        rays.clip(to: liquid)
        rays.blendMode = .plusLighter
        let surfaceY = bands[topIndex].top - amp
        let depth = h - surfaceY + 40
        for r in 0..<7 {
            let seed = rand(7, r, 1)
            let width = 26 + rand(7, r, 2) * 60
            let x = w * (Double(r) + 0.3 + seed * 0.4) / 7 + sin(t * 0.22 + Double(r) * 1.9) * 26
            let lean = 0.18 + rand(7, r, 3) * 0.12
            let strength = 0.07 + 0.06 * (0.5 + 0.5 * sin(t * 0.7 + Double(r) * 2.3))
            var ray = Path()
            ray.move(to: CGPoint(x: x - width / 2, y: surfaceY))
            ray.addLine(to: CGPoint(x: x + width / 2, y: surfaceY))
            ray.addLine(to: CGPoint(x: x + width * 1.4 + lean * depth, y: surfaceY + depth))
            ray.addLine(to: CGPoint(x: x - width * 0.4 + lean * depth, y: surfaceY + depth))
            ray.closeSubpath()
            rays.fill(ray, with: .linearGradient(
                Gradient(colors: [.white.opacity(strength), .white.opacity(0)]),
                startPoint: CGPoint(x: 0, y: surfaceY),
                endPoint: CGPoint(x: 0, y: surfaceY + depth * 0.75)))
        }
    }

    private func drawBubbles(_ ctx: inout GraphicsContext, layerIndex: Int, isFizzy: Bool,
                             top: Double, bottom: Double, width: Double, t: Double) {
        let height = max(bottom - top, 0)
        guard height > 8 else { return }
        let density = isFizzy ? 1.0 / 900 : 1.0 / 5000
        let count = min(Int(width * height * density) + (isFizzy ? 4 : 1), isFizzy ? 70 : 14)
        for j in 0..<count {
            let r1 = rand(layerIndex, j, 1), r2 = rand(layerIndex, j, 2), r3 = rand(layerIndex, j, 3), r4 = rand(layerIndex, j, 4)
            let speed = isFizzy ? 30 + r2 * 60 : 10 + r2 * 18
            let span = height + 40
            let progress = (t * speed + r4 * span).truncatingRemainder(dividingBy: span)
            let y = bottom + 20 - progress
            let x = r1 * width + sin(t * (1 + r3) + r4 * 6) * 3
            let radius = (isFizzy ? 1.2 : 1.6) + r3 * (isFizzy ? 2.2 : 3)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.18)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.45)), lineWidth: 0.8)
        }
    }

    private func drawFoam(_ ctx: inout GraphicsContext, seam: Path, surface: (Double) -> Double, width: Double, t: Double) {
        let foamHeight = 22.0
        var foam = Path()
        let xs = Array(stride(from: -12.0, through: width + 12, by: 6))
        foam.move(to: CGPoint(x: xs[0], y: surface(xs[0])))
        for x in xs.dropFirst() { foam.addLine(to: CGPoint(x: x, y: surface(x))) }
        for x in xs.reversed() {
            let bump = sin(x * 0.18 + t * 0.6) * 2.5 + sin(x * 0.07) * 3
            foam.addLine(to: CGPoint(x: x, y: surface(x) - foamHeight + bump))
        }
        foam.closeSubpath()
        ctx.fill(foam, with: .color(Color(hex: "FFF7E6")))
        var foamBubbles = ctx
        foamBubbles.clip(to: foam)
        for j in 0..<Int(width / 7) {
            let x = rand(99, j, 1) * width
            let y = surface(x) - rand(99, j, 2) * foamHeight
            let r = 2 + rand(99, j, 3) * 4
            foamBubbles.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                               with: .color(Color(hex: "E8D9B8").opacity(0.8)), lineWidth: 0.8)
        }
    }

    private func rand(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791))
        x ^= x >> 33
        x &*= 0xff51afd7ed558ccd
        x ^= x >> 33
        x &*= 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }
}

/// Vertical reflections and edge shading that read as curved glass.
private struct GlassHighlights: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0.02),
                .init(color: .white.opacity(0.28), location: 0.08),
                .init(color: .white.opacity(0), location: 0.15),
                .init(color: .white.opacity(0), location: 0.82),
                .init(color: .white.opacity(0.14), location: 0.88),
                .init(color: .white.opacity(0), location: 0.92),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.14), location: 0),
                .init(color: .clear, location: 0.06),
                .init(color: .clear, location: 0.94),
                .init(color: .black.opacity(0.14), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}
