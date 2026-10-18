import SwiftData
import SwiftUI

/// Create or edit a drink type, including optional estimated nutrition.
struct DrinkTypeEditorView: View {
    let type: DrinkType?
    var onCreate: ((DrinkType) -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue

    @State private var name = ""
    @State private var color = Color(hex: "7FC8A9")
    @State private var isFizzy = false
    @State private var isShown = true
    @State private var caffeine = ""
    @State private var sugar = ""
    @State private var kcal = ""
    @State private var loaded = false
    @State private var confirmDelete = false

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    /// Nutrition is stored per 100 ml but edited per the unit people think in.
    private var basisML: Double { unit == .metric ? 100 : 8 * Volume.mlPerFlOz }
    private var basisLabel: String { unit == .metric ? "100 ml" : "8 fl oz" }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Iced tea", text: $name)
                    .textInputAutocapitalization(.words)
            }
            Section("Look") {
                ColorPicker("Layer colour", selection: $color, supportsOpacity: false)
                Toggle("Fizzy (extra bubbles)", isOn: $isFizzy)
                if type?.isBuiltIn == true {
                    Toggle("Show in drink picker", isOn: $isShown)
                }
            }
            Section {
                nutritionField("Caffeine", unit: "mg", text: $caffeine)
                nutritionField("Sugar", unit: "g", text: $sugar)
                nutritionField("Energy", unit: "kcal", text: $kcal)
            } header: {
                Text("Estimated per \(basisLabel)")
            } footer: {
                Text("Optional rough estimates for your own reference. Leave blank if you don't know.")
            }
            if let type, !type.isBuiltIn {
                Section {
                    Button("Delete drink type", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Drinks you've already logged keep their name and colour.")
                }
            }
        }
        .navigationTitle(type == nil ? "New drink type" : "Edit drink type")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if type == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).fontWeight(.bold).disabled(trimmedName.isEmpty)
            }
        }
        .confirmationDialog("Delete this drink type?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let type { context.delete(type); try? context.save() }
                dismiss()
            }
        }
        .onAppear(perform: load)
    }

    private func nutritionField(_ title: String, unit: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text(unit).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func load() {
        guard !loaded, let type else { loaded = true; return }
        loaded = true
        name = type.name
        color = Color(hex: type.colorHex)
        isFizzy = type.isFizzy
        isShown = !type.isHidden
        let f = basisML / 100
        func str(_ v: Double?) -> String { v.map { Volume.number($0 * f, maxFraction: 1).replacingOccurrences(of: ",", with: "") } ?? "" }
        caffeine = str(type.caffeineMgPer100ml)
        sugar = str(type.sugarGPer100ml)
        kcal = str(type.kcalPer100ml)
    }

    private func save() {
        let f = 100 / basisML
        func per100(_ s: String) -> Double? { Volume.parse(s).map { max($0, 0) * f } }
        let target: DrinkType
        if let type {
            target = type
        } else {
            target = DrinkType(name: trimmedName, colorHex: color.hexString, sortOrder: 100)
            context.insert(target)
        }
        target.name = trimmedName
        target.colorHex = color.hexString
        target.isFizzy = isFizzy
        target.isHidden = !isShown
        target.caffeineMgPer100ml = per100(caffeine)
        target.sugarGPer100ml = per100(sugar)
        target.kcalPer100ml = per100(kcal)
        try? context.save()
        if type == nil { onCreate?(target) }
        dismiss()
    }
}

struct DrinkTypesListView: View {
    @Query(sort: \DrinkType.sortOrder) private var types: [DrinkType]
    @State private var showNew = false

    var body: some View {
        List {
            Section {
                ForEach(types) { type in
                    NavigationLink {
                        DrinkTypeEditorView(type: type)
                    } label: {
                        HStack(spacing: 12) {
                            Circle().fill(Color(hex: type.colorHex)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.primary.opacity(0.2), lineWidth: 1))
                            VStack(alignment: .leading) {
                                Text(type.name)
                                if type.isHidden {
                                    Text("Hidden from picker").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Nutrition values are estimates. Built-in drinks use typical values and can be adjusted.")
            }
        }
        .navigationTitle("Drink types")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: { Label("Add drink type", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showNew) {
            NavigationStack { DrinkTypeEditorView(type: nil) }
        }
    }
}
