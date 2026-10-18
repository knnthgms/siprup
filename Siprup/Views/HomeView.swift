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
    @Query private var recentEntries: [DrinkEntry]
    @Query(filter: #Predicate<DrinkType> { $0.isHidden == false }, sort: \DrinkType.sortOrder)
    private var types: [DrinkType]
    @AppStorage(Prefs.goalML) private var goalML = Prefs.defaultGoalML
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage(Prefs.reduceMotion) private var reduceMotionPref = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var context

    @State private var tilt = TiltSensor()
    @State private var sheet: HomeSheet?
    @State private var savedCount = 0
    @State private var lastAdded: DrinkEntry?

    enum HomeSheet: String, Identifiable {
        case add, today, history, settings, info
        var id: String { rawValue }
    }

    init(dayStart: Date, dayEnd: Date) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        let s = dayStart, e = dayEnd
        _entries = Query(filter: #Predicate<DrinkEntry> { $0.timestamp >= s && $0.timestamp < e },
                         sort: \DrinkEntry.timestamp)
        let since = dayStart.addingTimeInterval(-30 * 86_400)
        _recentEntries = Query(filter: #Predicate<DrinkEntry> { $0.timestamp >= since })
    }

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var reduceMotion: Bool { reduceMotionPref || systemReduceMotion }
    private var total: Double { entries.reduce(0) { $0 + $1.volumeML } }
    private var emptyGlassHex: String { colorScheme == .dark ? "16212B" : "F1F6F9" }

    /// One band per logged drink, oldest at the bottom.
    private var layers: [LiquidLayer] {
        entries.map { e in
            LiquidLayer(id: e.id.uuidString, name: e.displayName, colorHex: e.displayColorHex, time: e.timestamp,
                        volumeML: e.volumeML, isFizzy: e.type?.isFizzy ?? false, hasFoam: e.type?.hasFoam ?? false)
        }
    }

    /// The four drinks logged most over the last 30 days (sensible defaults before that), in a stable order.
    private var quickTypes: [DrinkType] {
        var counts: [UUID: Int] = [:]
        for e in recentEntries { if let t = e.type { counts[t.id, default: 0] += 1 } }
        let fallback = ["water", "coffee", "tea", "juice"]
        let ranked = types.sorted { a, b in
            let ca = counts[a.id] ?? 0, cb = counts[b.id] ?? 0
            if ca != cb { return ca > cb }
            let fa = fallback.firstIndex(of: a.key ?? "") ?? 99, fb = fallback.firstIndex(of: b.key ?? "") ?? 99
            if fa != fb { return fa < fb }
            return a.sortOrder < b.sortOrder
        }
        return ranked.prefix(4).sorted { $0.sortOrder < $1.sortOrder }
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
                            .accessibilityLabel("Glass illustration of today's drinks")
                            .accessibilityValue(layers.isEmpty
                                ? "Empty"
                                : layers.map { "\($0.name) \(Volume.format($0.volumeML, unit)) at \($0.time.formatted(date: .omitted, time: .shortened))" }
                                    .joined(separator: ", "))

                        LayerLabels(layers: layers, goalML: goalML, size: screen.size,
                                    zoneTop: insets.top + 215, zoneBottom: screen.size.height - insets.bottom - 120)
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
            // Screenshot/testing hook: launch with `-SiprupOpenSheet add|today|history|settings|info`.
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
            case .info:
                AboutGlassSheet()
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
            GlassIconButton(systemName: "info", label: "About the glass") { sheet = .info }
            GlassIconButton(systemName: "gearshape", label: "Settings") { sheet = .settings }
        }
    }

    private func headline(dark: Bool) -> some View {
        let progress = min(total / max(goalML, 1), 1)
        let parts = Volume.formatParts(total, unit)
        let status = total >= goalML
            ? "Goal reached"
            : "\(Int((progress * 100).rounded()))% of \(Volume.format(goalML, unit)) goal"
        return VStack(spacing: 2) {
            Button { sheet = .today } label: {
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
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Today: \(Volume.format(total, unit)) logged. \(status).")
            .accessibilityHint("Shows today's drinks")

            Button { sheet = .info } label: {
                Text("Visual log only · not a hydration measurement")
                    .font(.caption2.weight(.semibold))
                    .liquidText(dark: dark)
                    .opacity(0.85)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Explains the glass illustration")
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyHint: some View {
        Text("Your glass is empty.\nTap a drink below to start filling it.")
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
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(quickTypes) { type in
                Button { quickAdd(type) } label: {
                    VStack(spacing: 4) {
                        MiniGlass(color: type.color)
                        Text(type.shortName)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(Volume.format(type.quickServing, unit))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(type.name), \(Volume.format(type.quickServing, unit))")
                .accessibilityHint("Logs it right away")
            }
            Button { sheet = .add } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Color(.label), in: Circle())
                        .foregroundStyle(Color(.systemBackground))
                    Text("Other").font(.caption.weight(.bold))
                    Text("any size").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add another drink or size")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
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

/// A tiny tumbler filled with the drink's colour, used as the dock icon.
private struct MiniGlass: View {
    let color: Color

    var body: some View {
        ZStack {
            TumblerShape().fill(.white.opacity(0.35))
            TumblerShape().fill(color)
                .mask(alignment: .bottom) { Rectangle().frame(height: 22) }
            TumblerShape().stroke(.primary.opacity(0.55), lineWidth: 1.5)
        }
        .frame(width: 24, height: 30)
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
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
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

struct AboutGlassSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your screen is the glass")
                        .font(.title2.bold())
                    Text("As you log drinks, Siprup pours them into your screen as coloured layers — one band per drink, stacked in the order you logged them. It's a playful picture of your log, nothing more.")
                    InfoPoint(icon: "square.stack.3d.up", title: "Layers are a visual aid",
                              text: "Real drinks don't sit in layers inside your body. The stacking only helps you see what you've logged today.")
                    InfoPoint(icon: "ruler", title: "Not a hydration measurement",
                              text: "The level shows logged drinks against the goal you set. It can't tell how hydrated you are.")
                    InfoPoint(icon: "cup.and.saucer", title: "Every drink counts",
                              text: "All beverages, including coffee and tea, count toward your logged fluid. Siprup doesn't subtract anything.")
                    InfoPoint(icon: "stethoscope", title: "Not medical advice",
                              text: "Fluid needs vary with body, activity, climate and health. If a clinician has given you a fluid target or limit, follow their guidance.")
                }
                .padding(20)
            }
            .navigationTitle("About the glass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        // Opaque so the colourful liquid behind never reduces text contrast.
        .presentationBackground(Color(.systemBackground))
    }
}

private struct InfoPoint: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
