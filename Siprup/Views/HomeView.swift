import SwiftData
import SwiftUI

/// Tracks the current "day" (respecting the reset hour) and rebuilds the screen when it rolls over.
struct HomeView: View {
    @AppStorage(Prefs.resetHour) private var resetHour = Prefs.defaultResetHour
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @State private var now = Date()

    var body: some View {
        let clock = DayClock(resetHour: resetHour)
        let start = clock.dayStart(containing: now)
        HomeScreen(dayStart: start, dayEnd: clock.dayEnd(forStart: start))
            .id(start)
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    now = Date()
                    Task { await ReminderScheduler.refresh(context: context) }
                }
            }
    }
}

private struct HomeScreen: View {
    let dayStart: Date
    let dayEnd: Date

    @Query private var entries: [DrinkEntry]
    @Query(filter: #Predicate<DrinkType> { $0.isHidden == false }, sort: \DrinkType.sortOrder)
    private var types: [DrinkType]
    @AppStorage(Prefs.goalML) private var goalML = Prefs.defaultGoalML
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage(Prefs.reduceMotion) private var reduceMotionPref = false
    @AppStorage(Prefs.dockTypeIDs) private var dockRaw = ""
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var context

    @State private var tilt = TiltSensor()
    @State private var sheet: HomeSheet?
    @State private var savedCount = 0
    @State private var lastAdded: DrinkEntry?

    enum HomeSheet: String, Identifiable {
        case add, today, history, settings
        var id: String { rawValue }
    }

    init(dayStart: Date, dayEnd: Date) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        let s = dayStart, e = dayEnd
        _entries = Query(filter: #Predicate<DrinkEntry> { $0.timestamp >= s && $0.timestamp < e },
                         sort: \DrinkEntry.timestamp)
    }

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var reduceMotion: Bool { reduceMotionPref || systemReduceMotion }
    private var total: Double { entries.reduce(0) { $0 + $1.volumeML } }
    private var emptyGlassHex: String { colorScheme == .dark ? "16212B" : "F1F6F9" }
    private var pinned: [DrinkType] { DockPins.resolve(dockRaw, types: types) }

    /// One band per logged drink, oldest at the bottom.
    private var layers: [LiquidLayer] {
        entries.map { e in
            LiquidLayer(id: e.id.uuidString, name: e.displayName, colorHex: e.displayColorHex, time: e.timestamp,
                        volumeML: e.volumeML, isFizzy: e.type?.isFizzy ?? false, hasFoam: e.type?.hasFoam ?? false)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let fullHeight = geo.size.height + insets.top + insets.bottom
            // Pick text colour from whatever is actually behind the headline.
            let headlineHex = GlassGeometry.backgroundHex(atY: insets.top + 110, layers: layers, height: fullHeight,
                                                          goalML: goalML, emptyHex: emptyGlassHex)
            let darkHeadline = Contrast.prefersDarkText(onHex: headlineHex)
            ZStack {
                // The glass gets its own full-screen coordinate space so labels line up with the canvas.
                GeometryReader { screen in
                    ZStack {
                        LiquidGlassView(layers: layers, goalML: goalML, reduceMotion: reduceMotion, tilt: tilt)
                            .accessibilityElement()
                            .accessibilityLabel("Glass of today's drinks")
                            .accessibilityValue(layers.isEmpty
                                ? "Empty"
                                : layers.map { "\($0.name) \(Volume.format($0.volumeML, unit)) at \($0.time.formatted(date: .omitted, time: .shortened))" }
                                    .joined(separator: ", "))

                        LayerLabels(layers: layers, goalML: goalML, size: screen.size,
                                    zoneTop: insets.top + 200, zoneBottom: screen.size.height - insets.bottom - 110)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    headline(dark: darkHeadline)
                    Spacer()
                    if entries.isEmpty { emptyHint }
                    Spacer()
                    if let added = lastAdded { undoToast(added) }
                    dock
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.snappy, value: lastAdded?.id)
            }
        }
        .sensoryFeedback(.success, trigger: savedCount)
        .onAppear {
            updateTilt()
            #if DEBUG
            // Screenshot/testing hook: launch with `-SiprupOpenSheet add|today|history|settings`.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-SiprupOpenSheet"), i + 1 < args.count {
                sheet = HomeSheet(rawValue: args[i + 1])
            }
            #endif
        }
        .onChange(of: reduceMotion) { _, _ in updateTilt() }
        .onChange(of: entries.count) { old, new in if new > old { savedCount += 1 } }
        .task(id: lastAdded?.id) {
            guard lastAdded != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            lastAdded = nil
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .add:
                DrinkEditorView(mode: .add(defaultDate: Date()))
            case .today:
                NavigationStack {
                    DayLogView(dayStart: dayStart, dayEnd: dayEnd, goalML: goalML)
                        .navigationTitle("Today")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
                }
            case .history:
                HistoryView()
            case .settings:
                SettingsView()
            }
        }
    }

    private func updateTilt() {
        if reduceMotion { tilt.stop() } else { tilt.start() }
    }

    private func quickAdd(_ type: DrinkType) {
        let entry = DrinkEntry(timestamp: Date(), volumeML: type.quickServing, type: type)
        context.insert(entry)
        try? context.save()
        lastAdded = entry
        Task { await ReminderScheduler.refresh(context: context) }
    }

    private func undo(_ entry: DrinkEntry) {
        context.delete(entry)
        try? context.save()
        lastAdded = nil
        Task { await ReminderScheduler.refresh(context: context) }
    }

    // MARK: Overlays

    private var topBar: some View {
        HStack(spacing: 8) {
            GlassIconButton(systemName: "list.bullet", label: "Today's drinks") { sheet = .today }
            GlassIconButton(systemName: "calendar", label: "History") { sheet = .history }
            Spacer()
            GlassIconButton(systemName: "gearshape", label: "Settings") { sheet = .settings }
        }
    }

    private func headline(dark: Bool) -> some View {
        let progress = min(total / max(goalML, 1), 1)
        let parts = Volume.formatParts(total, unit)
        let status = total >= goalML
            ? "Goal reached"
            : "\(Int((progress * 100).rounded()))% of \(Volume.format(goalML, unit)) goal"
        return Button { sheet = .today } label: {
            VStack(spacing: 0) {
                Text("TODAY")
                    .font(.caption.weight(.heavy))
                    .tracking(2.5)
                    .opacity(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.number)
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(value: total))
                        .animation(.snappy, value: total)
                    Text(parts.unit)
                        .font(.title2.weight(.bold))
                        .opacity(0.85)
                }
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                Text(status)
                    .font(.headline)
            }
            .liquidText(dark: dark)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: \(Volume.format(total, unit)). \(status).")
        .accessibilityHint("Shows today's drinks")
    }

    private var emptyHint: some View {
        Text("Your glass is empty.\nTap a drink below to pour one in.")
            .font(.headline)
            .multilineTextAlignment(.center)
            .liquidText(dark: Contrast.prefersDarkText(onHex: emptyGlassHex))
    }

    private func undoToast(_ entry: DrinkEntry) -> some View {
        HStack {
            Text("Added \(entry.displayName) · \(Volume.format(entry.volumeML, unit))")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button("Undo") { undo(entry) }
                .font(.subheadline.weight(.bold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(.white)
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .background(DarkGlassBackground(shape: Capsule()))
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Minimal dark-glass dock: four pinned drinks plus "more".
    private var dock: some View {
        let pins = pinned
        return HStack(spacing: 0) {
            ForEach(Array(pins.enumerated()), id: \.element.id) { slot, type in
                Button { quickAdd(type) } label: {
                    VStack(spacing: 3) {
                        MiniGlass(color: type.color, foam: type.hasFoam)
                        Text(type.shortName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(Volume.format(type.quickServing, unit))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DockButtonStyle())
                .contextMenu {
                    Section("Swap for") {
                        ForEach(types.filter { $0.id != type.id }) { other in
                            Button(other.name) { dockRaw = DockPins.setting(other, slot: slot, in: pins) }
                        }
                    }
                }
                .accessibilityLabel("Add \(type.name), \(Volume.format(type.quickServing, unit))")
                .accessibilityHint("Logs it right away. Press and hold to swap this drink.")
            }
            Button { sheet = .add } label: {
                VStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.5))
                    Text("More")
                        .font(.caption.weight(.semibold))
                    Text(" ")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 70)
                .contentShape(Rectangle())
            }
            .buttonStyle(DockButtonStyle())
            .accessibilityLabel("Add another drink or size")
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(DarkGlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
    }
}

private extension DrinkType {
    var color: Color { Color(hex: colorHex) }
    /// "Orange juice" → "Juice" for the compact dock.
    var shortName: String {
        switch key {
        case "juice": return "Juice"
        case "sparkling": return "Sparkling"
        default: return name
        }
    }
}

/// Smoked, translucent glass — the same look in light and dark mode so it reads like part of the scene.
private struct DarkGlassBackground<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay(shape.fill(Color(hex: "0B1622").opacity(0.55)))
            .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.75))
    }
}

private struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// A tiny tumbler filled with the drink's colour, used as the dock icon.
private struct MiniGlass: View {
    let color: Color
    let foam: Bool

    var body: some View {
        ZStack {
            TumblerShape().fill(.white.opacity(0.12))
            TumblerShape()
                .fill(LinearGradient(colors: [color.shaded(0.15), color.shaded(-0.1)], startPoint: .top, endPoint: .bottom))
                .mask(alignment: .bottom) { Rectangle().frame(height: 21) }
            if foam {
                TumblerShape().fill(Color(hex: "FFF7E6"))
                    .mask(alignment: .bottom) { Rectangle().frame(height: 5).offset(y: -21) }
            }
            // Glass wall highlight.
            Capsule().fill(.white.opacity(0.45)).frame(width: 2, height: 18).offset(x: -7, y: 1)
            TumblerShape().stroke(.white.opacity(0.75), lineWidth: 1.25)
        }
        .frame(width: 22, height: 28)
        .accessibilityHidden(true)
    }
}

private struct TumblerShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.14, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.14, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(DarkGlassBackground(shape: Circle()))
        }
        .buttonStyle(DockButtonStyle())
        .accessibilityLabel(label)
    }
}

/// "Water · 6:20 PM" beside each band, coloured for contrast against that band.
private struct LayerLabels: View {
    let layers: [LiquidLayer]
    let goalML: Double
    let size: CGSize
    let zoneTop: Double
    let zoneBottom: Double

    var body: some View {
        let bands = GlassGeometry.bands(volumes: layers.map(\.volumeML), height: size.height, goalML: goalML)
        ZStack(alignment: .topLeading) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { i, layer in
                let top = max(bands[i].top, zoneTop)
                let bottom = min(bands[i].bottom, zoneBottom)
                if bottom - top >= 24 {
                    Text("\(layer.name) · \(layer.time.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.weight(.bold))
                        .liquidText(dark: Contrast.prefersDarkText(onHex: layer.colorHex))
                        .frame(width: size.width - 40, alignment: .trailing)
                        .position(x: size.width / 2, y: (top + bottom) / 2)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.6), value: layers)
    }
}
