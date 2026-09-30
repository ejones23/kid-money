import SwiftUI
import SwiftData

enum QuickAmountPreferences {
    static let storageKey = "quickAmountCents"
    static let defaults: [Int64] = [5, 10, 15, 20, 25, 50]
    static let maximumCount = 6
    static let defaultStorageValue = encode(defaults)

    static func decode(_ value: String) -> [Int64] {
        var seen = Set<Int64>()
        let amounts = value
            .split(separator: ",")
            .compactMap { Int64($0) }
            .filter { $0 > 0 && seen.insert($0).inserted }

        return amounts.isEmpty ? defaults : Array(amounts.prefix(maximumCount))
    }

    static func encode(_ amounts: [Int64]) -> String {
        amounts.map(String.init).joined(separator: ",")
    }
}

struct ChildListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Child> { !$0.isArchived }, sort: \Child.sortOrder) private var children: [Child]
    @AppStorage(QuickAmountPreferences.storageKey)
    private var storedQuickAmounts = QuickAmountPreferences.defaultStorageValue
    @State private var isShowingAddChild = false
    @State private var isShowingQuickAmountSettings = false
    @State private var direction: QuickAdjustmentDirection = .give
    @State private var errorMessage: String?
    @State private var completedActionCount = 0
    @State private var invitationNotice = CloudLedgerInvitationNotice.shared

    private var quickAmounts: [Int64] {
        QuickAmountPreferences.decode(storedQuickAmounts)
    }

    var body: some View {
        NavigationStack {
            Group {
                if children.isEmpty {
                    ContentUnavailableView {
                        Label("No Children Yet", systemImage: "person.2")
                    } description: {
                        Text("Add your children, then adjust their balances with the quick actions here.")
                    } actions: {
                        Button("Add Child") { isShowingAddChild = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            Picker("Adjustment type", selection: $direction) {
                                ForEach(QuickAdjustmentDirection.allCases) { option in
                                    Label(option.title, systemImage: option.systemImage)
                                        .tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)

                            ForEach(children) { child in
                                ChildQuickActionCard(
                                    child: child,
                                    amounts: quickAmounts,
                                    direction: direction
                                ) { cents in
                                    addTransaction(cents: direction.signed(cents), to: child)
                                }
                            }

                            AllChildrenQuickActionCard(
                                childCount: children.count,
                                amounts: quickAmounts,
                                direction: direction
                            ) { cents in
                                addTransactionToAllChildren(cents: direction.signed(cents))
                            }
                        }
                        .padding(.vertical)
                    }
                    .background(Color(.systemGroupedBackground))
                    .sensoryFeedback(.success, trigger: completedActionCount)
                }
            }
            .navigationTitle("Kid Money")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        FamilyLedgerSharingView()
                    } label: {
                        Label("Sharing", systemImage: "person.2")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Quick Amounts", systemImage: "slider.horizontal.3") {
                        isShowingQuickAmountSettings = true
                    }
                    Button("Add Child", systemImage: "plus") {
                        isShowingAddChild = true
                    }
                }
            }
            .navigationDestination(for: Child.self) { child in
                ChildDetailView(child: child)
            }
            .sheet(isPresented: $isShowingAddChild) {
                AddChildView()
            }
            .sheet(isPresented: $isShowingQuickAmountSettings) {
                QuickAmountSettingsView(storedAmounts: $storedQuickAmounts)
            }
            .alert("Couldn't Complete Action", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Family Invitation", isPresented: Binding(
                get: { invitationNotice.message != nil },
                set: { if !$0 { invitationNotice.message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(invitationNotice.message ?? "")
            }
        }
    }

    private func addTransaction(cents: Int64, to child: Child) {
        do {
            try LedgerService(modelContext: modelContext).addTransaction(cents: cents, to: child)
            completedActionCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTransactionToAllChildren(cents: Int64) {
        do {
            try LedgerService(modelContext: modelContext).addTransactionToAllActiveChildren(
                cents: cents,
                note: "Applied to all children"
            )
            completedActionCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum QuickAdjustmentDirection: String, CaseIterable, Identifiable {
    case give
    case take

    var id: String { rawValue }
    var title: String { self == .give ? "Give" : "Take" }
    var systemImage: String { self == .give ? "plus.circle.fill" : "minus.circle.fill" }
    var tint: Color { self == .give ? .green : .orange }
    var symbol: String { self == .give ? "+" : "−" }
    var preposition: String { self == .give ? "to" : "from" }

    func signed(_ cents: Int64) -> Int64 {
        self == .give ? cents : -cents
    }
}

private struct ChildQuickActionCard: View {
    let child: Child
    let amounts: [Int64]
    let direction: QuickAdjustmentDirection
    let onAdjust: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: child) {
                HStack(alignment: .firstTextBaseline) {
                    Text(child.name)
                        .font(.title2.bold())
                    Spacer()
                    Text(balance)
                        .font(.title3.bold().monospacedDigit())
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("\(child.name), balance \(balance), view history")

            QuickAmountGrid(
                amounts: amounts,
                direction: direction,
                accessibilityTarget: child.name,
                onAdjust: onAdjust
            )
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
        .padding(.horizontal)
    }

    private var balance: String {
        MoneyFormatter.string(cents: child.transactions.reduce(0) { $0 + $1.amountCents })
    }
}

private struct AllChildrenQuickActionCard: View {
    let childCount: Int
    let amounts: [Int64]
    let direction: QuickAdjustmentDirection
    let onAdjust: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("All Children", systemImage: "person.3.fill")
                    .font(.headline)
                Spacer()
                Text("\(childCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            QuickAmountGrid(
                amounts: amounts,
                direction: direction,
                accessibilityTarget: "all children",
                onAdjust: onAdjust
            )
        }
        .padding(16)
        .background(
            direction.tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(direction.tint.opacity(0.25), lineWidth: 1)
        }
        .padding(.horizontal)
    }
}

private struct QuickAmountGrid: View {
    let amounts: [Int64]
    let direction: QuickAdjustmentDirection
    let accessibilityTarget: String
    let onAdjust: (Int64) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(amounts, id: \.self) { cents in
                Button {
                    onAdjust(cents)
                } label: {
                    Text("\(direction.symbol)\(MoneyFormatter.string(cents: cents))")
                        .font(.subheadline.bold().monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(direction.tint)
                .accessibilityLabel(
                    "\(direction.title) \(MoneyFormatter.string(cents: cents)) \(direction.preposition) \(accessibilityTarget)"
                )
            }
        }
    }
}

private struct QuickAmountSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var storedAmounts: String
    @State private var amounts: [Int64]
    @State private var newAmount = ""
    @State private var errorMessage: String?
    @FocusState private var isAmountFocused: Bool

    init(storedAmounts: Binding<String>) {
        _storedAmounts = storedAmounts
        _amounts = State(initialValue: QuickAmountPreferences.decode(storedAmounts.wrappedValue))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(amounts, id: \.self) { cents in
                        HStack {
                            Text(MoneyFormatter.string(cents: cents))
                                .font(.body.monospacedDigit())
                            Spacer()
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                remove(cents)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    .onMove { source, destination in
                        amounts.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("Quick Amounts")
                } footer: {
                    Text("Choose up to six amounts. This order is used for every child and for All Children on this device.")
                }

                Section("Add an Amount") {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $newAmount)
                            .keyboardType(.decimalPad)
                            .focused($isAmountFocused)
                            .font(.body.monospacedDigit())
                        Button("Add") { addAmount() }
                            .disabled(
                                newAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || amounts.count >= QuickAmountPreferences.maximumCount
                            )
                    }
                }

                Section {
                    Button("Restore Defaults") {
                        amounts = QuickAmountPreferences.defaults
                    }
                }
            }
            .navigationTitle("Quick Amounts")
            .environment(\.editMode, .constant(.active))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        storedAmounts = QuickAmountPreferences.encode(amounts)
                        dismiss()
                    }
                    .disabled(amounts.isEmpty)
                }
            }
            .alert("Couldn't Add Amount", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func addAmount() {
        do {
            let cents = try MoneyConversion.usdCents(from: newAmount)
            guard !amounts.contains(cents) else {
                errorMessage = "That amount is already in your quick actions."
                return
            }
            guard amounts.count < QuickAmountPreferences.maximumCount else {
                errorMessage = "You can show up to six quick amounts."
                return
            }
            amounts.append(cents)
            newAmount = ""
            isAmountFocused = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ cents: Int64) {
        amounts.removeAll { $0 == cents }
    }
}
