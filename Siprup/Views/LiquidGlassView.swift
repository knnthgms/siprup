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

/// One slanted shaft of light under the surface. Shared by the ray drawing and bubble lighting.
private struct LightRay {
    let x: Double       // centre where it enters the surface
    let width: Double
    let lean: Double    // horizontal drift per point of depth
    let strength: Double
}

/// The whole screen as the side of a glass, with the day's drinks poured in as bands.
struct LiquidGlassView: View {
    let layers: [LiquidLayer]
    let goalML: Double
    let reduceMotion: Bool
    let tilt: TiltSensor

    @State private var sim = LiquidSim()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let _ = sim.step(time: now, targetAngle: reduceMotion ? 0 : tilt.angle, targets: layers, animate: !reduceMotion)
                let t = reduceMotion ? 0 : now.truncatingRemainder(dividingBy: 3600)
                let surfaceY = currentSurfaceY(height: geo.size.height)
                let hasLiquid = surfaceY < geo.size.height - 0.5

                Canvas { ctx, size in
                    drawGlass(&ctx, size: size)
                    drawLiquid(&ctx, size: size, t: t)
                }
                .layerEffect(
                    ShaderLibrary.liquidLight(.float(t), .float2(geo.size), .float(surfaceY), .float(tan(sim.angle)),
                                              .float(reduceMotion ? 0 : 1)),
                    maxSampleOffset: CGSize(width: 3, height: 3),
                    isEnabled: hasLiquid
                )
            }
        }
        .overlay { GlassHighlights().allowsHitTesting(false) }
        .background(colorScheme == .dark ? Color(hex: "0E151C") : Color(hex: "E9F1F6"))
    }

    private func currentSurfaceY(height: Double) -> Double {
        let volumes = layers.map { sim.displayed[$0.id] ?? 0 }
        guard volumes.reduce(0, +) > 0.5 else { return height }
        return GlassGeometry.bands(volumes: volumes, height: height, goalML: goalML).last?.top ?? height
    }

    // MARK: Drawing

    private func drawGlass(_ ctx: inout GraphicsContext, size: CGSize) {
        let colors = colorScheme == .dark
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
        let amp = reduceMotion ? 0 : 2.2 + 9 * sim.energy + min(abs(sim.angularVelocity) * 10, 10)
        let topIndex = layers.indices.last { volumes[$0] > 0.5 } ?? 0
        let xs = Array(stride(from: -12.0, through: w + 12, by: 5))

        /// Height of a boundary at x. The top surface also climbs the glass walls (meniscus).
        func surface(_ baseY: Double, _ x: Double, waveScale: Double, meniscus: Bool = false) -> Double {
            let k = x / w * 2 * .pi
            let wave = sin(k * 1.3 + t * 1.7) + 0.5 * sin(k * 2.9 - t * 2.4) + 0.18 * sin(k * 7.3 + t * 3.6)
            var y = baseY - slope * (x - cx) + waveScale * amp * wave
            if meniscus { y -= 9 * exp(-max(x, 0) / 11) + 9 * exp(-max(w - x, 0) / 11) }
            return y
        }

        func line(_ baseY: Double, waveScale: Double, meniscus: Bool = false) -> Path {
            var p = Path()
            for (j, x) in xs.enumerated() {
                let pt = CGPoint(x: x, y: surface(baseY, x, waveScale: waveScale, meniscus: meniscus))
                if j == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }

        func band(top: Double, bottom: Double?, topWave: Double, bottomWave: Double, meniscus: Bool) -> Path {
            var p = line(top, waveScale: topWave, meniscus: meniscus)
            if let bottom {
                for x in xs.reversed() { p.addLine(to: CGPoint(x: x, y: surface(bottom, x, waveScale: bottomWave))) }
            } else {
                p.addLine(to: CGPoint(x: w + 12, y: h + 200))
                p.addLine(to: CGPoint(x: -12, y: h + 200))
            }
            p.closeSubpath()
            return p
        }

        let surfaceY = bands[topIndex].top
        let liquid = band(top: surfaceY, bottom: nil, topWave: 1, bottomWave: 0, meniscus: true)
        let rays = lightRays(width: w, t: t)
        let depth = h - surfaceY + 40
        func light(at x: Double, _ y: Double) -> Double {
            let d = y - surfaceY
            guard d > 0 else { return 0 }
            var sum = 0.0
            for r in rays {
                let centre = r.x + r.width * 0.45 + r.lean * d
                let spread = r.width * (0.5 + d / depth * 0.6)
                let off = (x - centre) / spread
                sum += exp(-off * off * 2) * r.strength / 0.13
            }
            return min(sum * (1 - min(d / depth, 1) * 0.6), 1)
        }

        // 1. Bands, each a body of colour with a soft top-to-bottom tint.
        for (i, layer) in layers.enumerated() where volumes[i] > 0.5 {
            let isTop = i == topIndex
            let path = band(top: bands[i].top, bottom: i == 0 ? nil : bands[i].bottom,
                            topWave: isTop ? 1 : 0.22, bottomWave: i == 0 ? 0 : 0.22, meniscus: isTop)
            let c = layer.color
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [c.shaded(0.14), c, c.shaded(-0.08)]),
                startPoint: CGPoint(x: 0, y: bands[i].top - 20),
                endPoint: CGPoint(x: 0, y: max(bands[i].bottom, bands[i].top + 60))))

            // Sheen under each band's top, where light enters it.
            var sheen = ctx
            sheen.clip(to: path)
            let glossTop = bands[i].top - amp - 16
            sheen.fill(Path(CGRect(x: 0, y: glossTop, width: w, height: 48 + amp)),
                       with: .linearGradient(
                           Gradient(stops: [
                               .init(color: .white.opacity(0), location: 0),
                               .init(color: .white.opacity(isTop ? 0.32 : 0.2), location: 0.42),
                               .init(color: .white.opacity(0), location: 1),
                           ]),
                           startPoint: CGPoint(x: 0, y: glossTop),
                           endPoint: CGPoint(x: 0, y: glossTop + 48 + amp)))
        }

        // 2. Soft, slightly diffused interfaces where one drink meets the next.
        ctx.drawLayer { layer in
            layer.clip(to: liquid)
            layer.addFilter(.blur(radius: 5))
            for i in layers.indices.dropFirst() where volumes[i] > 0.5 && i <= topIndex {
                let seam = line(bands[i].bottom, waveScale: 0.22)
                layer.stroke(seam, with: .color(layers[i - 1].color.opacity(0.55)), lineWidth: 8)
            }
        }
        for i in layers.indices.dropFirst() where volumes[i] > 0.5 && i <= topIndex {
            ctx.stroke(line(bands[i].bottom, waveScale: 0.22), with: .color(.white.opacity(0.16)), lineWidth: 1)
        }

        // 3. Depth: liquid absorbs light, so it darkens gently toward the bottom of the glass.
        ctx.drawLayer { layer in
            layer.clip(to: liquid)
            layer.fill(Path(CGRect(x: 0, y: surfaceY - 20, width: w, height: h - surfaceY + 40)),
                       with: .linearGradient(
                           Gradient(colors: [.clear, .black.opacity(0.06), .black.opacity(0.26)]),
                           startPoint: CGPoint(x: 0, y: surfaceY),
                           endPoint: CGPoint(x: 0, y: h)))
        }

        // 4. Soft light shafts slanting down from the surface.
        ctx.drawLayer { layer in
            layer.clip(to: liquid)
            layer.blendMode = .plusLighter
            layer.addFilter(.blur(radius: 9))
            for r in rays {
                var ray = Path()
                ray.move(to: CGPoint(x: r.x, y: surfaceY - 10))
                ray.addLine(to: CGPoint(x: r.x + r.width, y: surfaceY - 10))
                ray.addLine(to: CGPoint(x: r.x + r.width * 1.6 + r.lean * depth, y: surfaceY + depth))
                ray.addLine(to: CGPoint(x: r.x - r.width * 0.3 + r.lean * depth, y: surfaceY + depth))
                ray.closeSubpath()
                layer.fill(ray, with: .linearGradient(
                    Gradient(colors: [.white.opacity(r.strength * 1.5), .white.opacity(r.strength * 0.5), .white.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: surfaceY),
                    endPoint: CGPoint(x: 0, y: surfaceY + depth * 0.8)))
            }
        }

        // 5. Bubbles: rising, growing, wobbling, and catching the light where shafts cross them.
        for (i, layer) in layers.enumerated() where volumes[i] > 0.5 {
            let isTop = i == topIndex
            let path = band(top: bands[i].top, bottom: i == 0 ? nil : bands[i].bottom,
                            topWave: isTop ? 1 : 0.22, bottomWave: i == 0 ? 0 : 0.22, meniscus: isTop)
            var bubbles = ctx
            bubbles.clip(to: path)
            drawRisingBubbles(&bubbles, layerIndex: i, isFizzy: layer.isFizzy,
                              top: bands[i].top, bottom: i == 0 ? h : bands[i].bottom, width: w, t: t, light: light)
            drawClingingBubbles(&bubbles, layerIndex: i, isFizzy: layer.isFizzy,
                                top: bands[i].top, bottom: i == 0 ? h : bands[i].bottom, width: w, light: light)
        }

        // 6. The surface: bright refracting edge, total-internal-reflection sheet, travelling glints.
        let top = line(surfaceY, waveScale: 1, meniscus: true)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(top.offsetBy(dx: 0, dy: 4), with: .color(.white.opacity(0.32)), lineWidth: 6)
        }
        ctx.stroke(top, with: .color(.white.opacity(0.75)), lineWidth: 1.6)
        if !reduceMotion {
            ctx.stroke(top, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [18, 70], dashPhase: -t * 24))
            ctx.stroke(top.offsetBy(dx: 0, dy: 1), with: .color(.white.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [8, 110], dashPhase: t * 15))
        }

        let topLayer = layers[topIndex]
        if topLayer.isFizzy && !topLayer.hasFoam {
            drawSurfaceFizz(&ctx, width: w, t: t) { surface(surfaceY, $0, waveScale: 1, meniscus: true) }
        }
        if topLayer.hasFoam {
            drawFoam(&ctx, width: w, t: t) { surface(surfaceY, $0, waveScale: 1, meniscus: true) }
        }
    }

    private func lightRays(width w: Double, t: Double) -> [LightRay] {
        (0..<6).map { r in
            let seed = rand(7, r, 1)
            return LightRay(
                x: w * (Double(r) + 0.15 + seed * 0.5) / 6 + sin(t * 0.18 + Double(r) * 1.9) * 22,
                width: 22 + rand(7, r, 2) * 46,
                lean: 0.2 + rand(7, r, 3) * 0.1,
                strength: 0.06 + 0.06 * (0.5 + 0.5 * sin(t * 0.6 + Double(r) * 2.3)))
        }
    }

    /// A single bubble: clear body, bright rim, specular highlight — all brighter where light hits it.
    private func drawBubble(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, light: Double, alpha: Double = 1) {
        let lit = (0.55 + 0.9 * light) * alpha
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.04 * lit), .white.opacity(0.1 * lit), .white.opacity(0.42 * lit)]),
            center: p, startRadius: 0, endRadius: r))
        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 0.3, dy: 0.3)), with: .color(.white.opacity(min(0.55 * lit, 0.95))),
                   lineWidth: max(0.6, r * 0.14))
        // Darker refracted crescent at the bottom gives the bubble volume.
        var crescent = Path()
        crescent.addArc(center: p, radius: r * 0.78, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
        ctx.stroke(crescent, with: .color(.black.opacity(0.12 * alpha)), lineWidth: max(0.5, r * 0.18))
        let s = max(0.7, r * 0.3)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.45 - s / 2, y: p.y - r * 0.45 - s / 2, width: s, height: s)),
                 with: .color(.white.opacity(min(0.75 * lit, 1))))
    }

    private func drawRisingBubbles(_ ctx: inout GraphicsContext, layerIndex: Int, isFizzy: Bool,
                                   top: Double, bottom: Double, width: Double, t: Double,
                                   light: (Double, Double) -> Double) {
        let height = max(bottom - top, 0)
        guard height > 8 else { return }
        let density = isFizzy ? 1.0 / 800 : 1.0 / 4500
        let count = min(Int(width * height * density) + (isFizzy ? 5 : 1), isFizzy ? 80 : 16)
        let span = height + 30
        for j in 0..<count {
            let r1 = rand(layerIndex, j, 1), r2 = rand(layerIndex, j, 2), r3 = rand(layerIndex, j, 3), r4 = rand(layerIndex, j, 4)
            let speed = isFizzy ? 34 + r2 * 60 : 9 + r2 * 16
            // Bubbles accelerate and swell a little as they rise (less pressure above).
            let phase = (t * speed / span + r4).truncatingRemainder(dividingBy: 1)
            let rise = span * pow(phase, 1.25)
            let y = bottom + 15 - rise
            let x = r1 * width + sin(t * (1.4 + r3) + r4 * 6) * (1.5 + phase * 3)
            let base = (isFizzy ? 1.0 : 1.5) + r3 * (isFizzy ? 2.2 : 3.2)
            let radius = base * (0.75 + 0.5 * phase)
            drawBubble(&ctx, at: CGPoint(x: x, y: y), radius: radius, light: light(x, y))
        }
    }

    /// Bubbles stuck to the glass walls, as in a real poured drink.
    private func drawClingingBubbles(_ ctx: inout GraphicsContext, layerIndex: Int, isFizzy: Bool,
                                     top: Double, bottom: Double, width: Double,
                                     light: (Double, Double) -> Double) {
        let height = bottom - top
        guard height > 14 else { return }
        let count = isFizzy ? min(Int(height / 10) + 2, 26) : min(Int(height / 60), 4)
        for j in 0..<count {
            let leftSide = rand(layerIndex, j, 11) < 0.5
            let inset = 3 + rand(layerIndex, j, 12) * 16
            let x = leftSide ? inset : width - inset
            let y = top + 8 + rand(layerIndex, j, 13) * (height - 12)
            let r = 0.9 + rand(layerIndex, j, 14) * (isFizzy ? 2.6 : 2)
            drawBubble(&ctx, at: CGPoint(x: x, y: y), radius: r, light: light(x, y) * 0.6, alpha: 0.85)
        }
    }

    /// Fizz popping at the surface of carbonated drinks.
    private func drawSurfaceFizz(_ ctx: inout GraphicsContext, width: Double, t: Double, surface: (Double) -> Double) {
        for j in 0..<22 {
            let x = rand(31, j, 1) * width
            let phase = (t * (0.7 + rand(31, j, 2) * 0.9) + rand(31, j, 3)).truncatingRemainder(dividingBy: 1)
            guard phase < 0.3 else { continue }
            let p = phase / 0.3
            let r = 1 + p * 5
            let y = surface(x) + 1.5
            ctx.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r * 0.45, width: r * 2, height: r * 0.9)),
                       with: .color(.white.opacity((1 - p) * 0.7)), lineWidth: 0.8)
        }
    }

    private func drawFoam(_ ctx: inout GraphicsContext, width: Double, t: Double, surface: (Double) -> Double) {
        let foamHeight = 24.0
        let xs = Array(stride(from: -12.0, through: width + 12, by: 5))
        var foam = Path()
        foam.move(to: CGPoint(x: xs[0], y: surface(xs[0]) + 2))
        for x in xs.dropFirst() { foam.addLine(to: CGPoint(x: x, y: surface(x) + 2)) }
        for x in xs.reversed() {
            let bump = sin(x * 0.17 + t * 0.5) * 2.2 + sin(x * 0.061) * 3 + sin(x * 0.43) * 1.2
            foam.addLine(to: CGPoint(x: x, y: surface(x) - foamHeight + bump))
        }
        foam.closeSubpath()
        let mid = surface(width / 2)
        ctx.fill(foam, with: .linearGradient(
            Gradient(colors: [Color(hex: "FFFDF7"), Color(hex: "FBF1DA"), Color(hex: "EFDDB4")]),
            startPoint: CGPoint(x: 0, y: mid - foamHeight), endPoint: CGPoint(x: 0, y: mid + 2)))
        var inner = ctx
        inner.clip(to: foam)
        for j in 0..<Int(width / 4) {
            let x = rand(99, j, 1) * width
            let y = surface(x) + 2 - rand(99, j, 2) * foamHeight
            let r = 1.5 + rand(99, j, 3) * 4.5
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            inner.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)))
            inner.stroke(Path(ellipseIn: rect), with: .color(Color(hex: "D9C49A").opacity(0.55)), lineWidth: 0.7)
        }
        ctx.stroke(foam, with: .color(.white.opacity(0.4)), lineWidth: 0.8)
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
                .init(color: .white.opacity(0.26), location: 0.075),
                .init(color: .white.opacity(0.08), location: 0.1),
                .init(color: .white.opacity(0), location: 0.16),
                .init(color: .white.opacity(0), location: 0.83),
                .init(color: .white.opacity(0.12), location: 0.885),
                .init(color: .white.opacity(0), location: 0.92),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.16), location: 0),
                .init(color: .clear, location: 0.06),
                .init(color: .clear, location: 0.94),
                .init(color: .black.opacity(0.16), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}
