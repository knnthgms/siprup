import SwiftData
import SwiftUI

/// Add a new drink or edit/delete an existing entry.
struct DrinkEditorView: View {
    enum Mode {
        case add(defaultDate: Date)
        case edit(DrinkEntry)
    }

    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<DrinkType> { $0.isHidden == false }, sort: \DrinkType.sortOrder)
    private var types: [DrinkType]
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage(Prefs.showNutrition) private var showNutrition = true

    @State private var selectedTypeID: UUID?
    @State private var amountText = ""
    @State private var time = Date()
    @State private var loaded = false
    @State private var showNewType = false
    @State private var confirmDelete = false
    @FocusState private var amountFocused: Bool

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var selectedType: DrinkType? { types.first { $0.id == selectedTypeID } }
    private var amountML: Double? {
        guard let v = Volume.parse(amountText), v > 0 else { return nil }
        let ml = Volume.toML(v, unit)
        return (1...5000).contains(ml) ? ml : nil
    }
    private var isEditing: Bool { if case .edit = mode { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Drink") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(types) { type in
                            TypeChip(name: type.name, colorHex: type.colorHex, selected: type.id == selectedTypeID) {
                                selectedTypeID = type.id
                            }
                        }
                        Button { showNewType = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").font(.title2)
                                Text("New type").font(.footnote.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }

                Section("Amount") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Volume.presets(unit)) { preset in
                                let selected = amountML.map { abs($0 - preset.ml) < 0.5 } ?? false
                                Button {
                                    amountText = Volume.editableString(preset.ml, unit)
                                    amountFocused = false
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(Volume.format(preset.ml, unit)).font(.subheadline.weight(.semibold))
                                        Text(preset.name).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 48)
                                    .background(selected ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill),
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(preset.name), \(Volume.format(preset.ml, unit))")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    HStack {
                        TextField("Custom amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.title2.weight(.semibold))
                            .focused($amountFocused)
                            .accessibilityLabel("Amount in \(unit.shortLabel)")
                        Text(unit.shortLabel).foregroundStyle(.secondary)
                    }
                    if !amountText.isEmpty && amountML == nil {
                        Text("Enter an amount between \(Volume.format(1, unit)) and \(Volume.format(5000, unit)).")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("When") {
                    DatePicker("Time", selection: $time, in: ...Date().addingTimeInterval(300),
                               displayedComponents: [.date, .hourAndMinute])
                }

                if showNutrition, let type = selectedType, let ml = amountML {
                    let est = NutritionEstimate(type: type, volumeML: ml)
                    Section {
                        if est.isEmpty {
                            Text("No estimate for this drink. You can add one in Settings → Drink types.")
                                .foregroundStyle(.secondary)
                        } else {
                            NutritionRows(estimate: est)
                        }
                    } header: {
                        Text("Estimated (approximate)")
                    } footer: {
                        Text("Rough typical values — real drinks vary. Everything you log counts toward your fluid total.")
                    }
                }

                if case .edit = mode {
                    Section {
                        Button("Delete entry", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit drink" : "Add drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                        .disabled(selectedType == nil || amountML == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { amountFocused = false }
                }
            }
            .confirmationDialog("Delete this drink?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: delete)
            }
            .sheet(isPresented: $showNewType) {
                NavigationStack {
                    DrinkTypeEditorView(type: nil) { newType in selectedTypeID = newType.id }
                }
            }
            .onAppear(perform: load)
            .onChange(of: selectedTypeID) { old, _ in
                // When adding, picking a drink pre-fills its usual size.
                if case .add = mode, old != nil, let type = selectedType {
                    amountText = Volume.editableString(type.quickServing, unit)
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .add(let date):
            selectedTypeID = types.first?.id
            amountText = Volume.editableString(types.first?.quickServing ?? 250, unit)
            time = min(date, Date())
        case .edit(let entry):
            selectedTypeID = entry.type?.id
            amountText = Volume.editableString(entry.volumeML, unit)
            time = entry.timestamp
        }
    }

    private func save() {
        guard let type = selectedType, let ml = amountML else { return }
        switch mode {
        case .add:
            context.insert(DrinkEntry(timestamp: time, volumeML: ml, type: type))
        case .edit(let entry):
            entry.volumeML = ml
            entry.timestamp = time
            entry.setType(type)
        }
        try? context.save()
        Task { await ReminderScheduler.refresh(context: context) }
        dismiss()
    }

    private func delete() {
        guard case .edit(let entry) = mode else { return }
        context.delete(entry)
        try? context.save()
        Task { await ReminderScheduler.refresh(context: context) }
        dismiss()
    }
}

private struct TypeChip: View {
    let name: String
    let colorHex: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: colorHex))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.primary.opacity(0.2), lineWidth: 1))
                Text(name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selected ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NutritionRows: View {
    let estimate: NutritionEstimate

    var body: some View {
        if let c = estimate.caffeineMg {
            LabeledContent("Caffeine", value: "≈ \(Volume.number(c, maxFraction: 0)) mg")
        }
        if let s = estimate.sugarG {
            LabeledContent("Sugar", value: "≈ \(Volume.number(s, maxFraction: 1)) g")
        }
        if let k = estimate.kcal {
            LabeledContent("Energy", value: "≈ \(Volume.number(k, maxFraction: 0)) kcal")
        }
    }
}
