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
    @AppStorage(Prefs.goalML) private var goalML = Prefs.defaultGoalML
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage(Prefs.reduceMotion) private var reduceMotionPref = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var tilt = TiltSensor()
    @State private var sheet: HomeSheet?
    @State private var savedCount = 0

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
    }

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var reduceMotion: Bool { reduceMotionPref || systemReduceMotion }
    private var total: Double { entries.reduce(0) { $0 + $1.volumeML } }

    private var layers: [LiquidLayer] {
        var order: [String] = []
        var byKey: [String: LiquidLayer] = [:]
        for e in entries {
            let key = e.layerKey
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = LiquidLayer(id: key, name: e.displayName, colorHex: e.displayColorHex, volumeML: 0,
                                         isFizzy: e.type?.isFizzy ?? false, hasFoam: e.type?.hasFoam ?? false)
            }
            byKey[key]?.volumeML += e.volumeML
        }
        return order.compactMap { byKey[$0] }
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            ZStack {
                // The glass gets its own full-screen coordinate space so labels line up with the canvas.
                GeometryReader { screen in
                    ZStack {
                        LiquidGlassView(layers: layers, goalML: goalML, reduceMotion: reduceMotion, tilt: tilt)
                            .accessibilityElement()
                            .accessibilityLabel("Glass illustration of today's drinks")
                            .accessibilityValue(layers.isEmpty
                                ? "Empty"
                                : layers.map { "\($0.name) \(Volume.format($0.volumeML, unit))" }.joined(separator: ", "))

                        LayerLabels(layers: layers, goalML: goalML, unit: unit, size: screen.size,
                                    zoneTop: insets.top + 190, zoneBottom: screen.size.height - insets.bottom - 96)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topCard
                    Spacer()
                    if entries.isEmpty { emptyHint }
                    Spacer()
                    bottomBar
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
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

    // MARK: Overlays

    private var topCard: some View {
        let progress = min(total / max(goalML, 1), 1)
        let met = total >= goalML
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Siprup")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                Text(dayStart.formatted(.dateTime.weekday(.wide).day().month()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(systemName: "info.circle", label: "About the glass") { sheet = .info }
                IconButton(systemName: "gearshape", label: "Settings") { sheet = .settings }
            }
            Text(Volume.format(total, unit))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .contentTransition(.numericText(value: total))
                .animation(.snappy, value: total)
                .accessibilityLabel("Logged today: \(Volume.format(total, unit))")
            Text(met
                 ? "Goal of \(Volume.format(goalML, unit)) reached — nicely done."
                 : "of \(Volume.format(goalML, unit)) goal · \(Int((progress * 100).rounded()))%")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .tint(met ? .green : .accentColor)
                .accessibilityLabel("Progress toward goal")
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            Button { sheet = .info } label: {
                Label("Visual log only — not a hydration measurement", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var emptyHint: some View {
        Text("Your glass is empty.\nLog a drink to start filling it.")
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            RoundButton(systemName: "list.bullet", label: "Today's drinks") { sheet = .today }
            Button { sheet = .add } label: {
                Label("Add drink", systemImage: "plus")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .foregroundStyle(Color(.systemBackground))
            .background(Color(.label), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            RoundButton(systemName: "calendar", label: "History") { sheet = .history }
        }
    }
}

private struct LayerLabels: View {
    let layers: [LiquidLayer]
    let goalML: Double
    let unit: UnitSystem
    let size: CGSize
    let zoneTop: Double
    let zoneBottom: Double

    var body: some View {
        let bands = GlassGeometry.bands(volumes: layers.map(\.volumeML), height: size.height, goalML: goalML)
        ZStack(alignment: .topLeading) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { i, layer in
                let top = max(bands[i].top, zoneTop)
                let bottom = min(bands[i].bottom, zoneBottom)
                if bottom - top >= 30 {
                    HStack(spacing: 6) {
                        Circle().fill(layer.color).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 0.5))
                        Text("\(layer.name) · \(Volume.format(layer.volumeML, unit))")
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .position(x: size.width - 110, y: (top + bottom) / 2)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.6), value: layers)
    }
}

struct RoundButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .frame(width: 58, height: 58)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
                    Text("As you log drinks, Siprup pours them into your screen as coloured layers — one layer per drink type, in the order you first logged it. It's a playful picture of your log, nothing more.")
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
