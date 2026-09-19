import SwiftUI
import SwiftData

struct ChildDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let child: Child
    @State private var errorMessage: String?
    @State private var adjustmentMode: ManualAdjustmentMode?
    @State private var isRenaming = false
    @State private var isConfirmingArchive = false

    private let quickAmounts: [Int64] = [5, 10, 25, 100]

    var body: some View {
        let service = LedgerService(modelContext: modelContext)
        List {
            Section {
                VStack(spacing: 8) {
                    Text("Current Balance")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(MoneyFormatter.string(cents: service.balance(for: child)))
                        .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .accessibilityLabel("Current balance")
                        .accessibilityValue(MoneyFormatter.string(cents: service.balance(for: child)))
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section("Quick Add") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(quickAmounts, id: \.self) { cents in
                        Button {
                            addTransaction(cents: cents)
                        } label: {
                            Text("+\(MoneyFormatter.string(cents: cents))")
                                .font(.headline.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Add \(MoneyFormatter.string(cents: cents))")
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Custom Adjustment") {
                Button("Add Money", systemImage: "plus.circle") {
                    adjustmentMode = .add
                }
                Button("Subtract Money", systemImage: "minus.circle") {
                    adjustmentMode = .subtract
                }
            }

            Section("History") {
                let transactions = sortedTransactions
                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No Transactions Yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Siri and manual adjustments will appear here.")
                    )
                } else {
                    ForEach(transactions) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                }
            }
        }
        .navigationTitle(child.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Manage Child", systemImage: "ellipsis.circle") {
                    Button("Rename", systemImage: "pencil") { isRenaming = true }
                    Button("Archive", systemImage: "archivebox", role: .destructive) {
                        isConfirmingArchive = true
                    }
                }
            }
        }
        .sheet(item: $adjustmentMode) { mode in
            ManualAdjustmentView(child: child, mode: mode)
        }
        .sheet(isPresented: $isRenaming) {
            RenameChildView(child: child)
        }
        .confirmationDialog(
            "Archive \(child.name)?",
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button("Archive Child", role: .destructive) { archiveChild() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The child will disappear from the active list, but their complete ledger history will remain stored.")
        }
        .alert("Couldn't Complete Action", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var sortedTransactions: [LedgerTransaction] {
        child.transactions.sorted { $0.createdAt > $1.createdAt }
    }

    private func addTransaction(cents: Int64) {
        do {
            try LedgerService(modelContext: modelContext).addTransaction(cents: cents, to: child)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archiveChild() {
        do {
            try LedgerService(modelContext: modelContext).archiveChild(child)
            KidMoneyShortcuts.updateAppShortcutParameters()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TransactionRow: View {
    let transaction: LedgerTransaction

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.reversesTransactionID == nil ? transaction.source.displayName : "Undo")
                    .font(.body)
                Text(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = transaction.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(signedAmount)
                .font(.headline.monospacedDigit())
                .foregroundStyle(transaction.amountCents >= 0 ? Color.green : Color.primary)
                .accessibilityLabel(transaction.amountCents >= 0 ? "Added" : "Removed")
                .accessibilityValue(MoneyFormatter.string(cents: transaction.amountCents.magnitudeAsInt64))
        }
    }

    private var signedAmount: String {
        if transaction.amountCents > 0 {
            return "+\(MoneyFormatter.string(cents: transaction.amountCents))"
        }
        return MoneyFormatter.string(cents: transaction.amountCents)
    }
}

private enum ManualAdjustmentMode: String, Identifiable {
    case add
    case subtract

    var id: String { rawValue }
    var title: String { self == .add ? "Add Money" : "Subtract Money" }
    var actionTitle: String { self == .add ? "Add" : "Subtract" }
    var sign: Int64 { self == .add ? 1 : -1 }
}

private struct ManualAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let child: Child
    let mode: ManualAdjustmentMode
    @State private var amount = ""
    @State private var note = ""
    @State private var errorMessage: String?
    @FocusState private var isAmountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amount)
                            .keyboardType(.decimalPad)
                            .focused($isAmountFocused)
                            .font(.title2.monospacedDigit())
                            .accessibilityLabel("Amount in dollars")
                    }
                    TextField("Note (optional)", text: $note)
                } footer: {
                    Text("Enter a positive US dollar amount. Kid Money stores the adjustment as exact cents.")
                }
            }
            .navigationTitle(mode.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.actionTitle) { save() }
                        .disabled(amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isAmountFocused = true }
            .alert("Couldn't Save Transaction", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            let cents = try MoneyConversion.usdCents(from: amount)
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try LedgerService(modelContext: modelContext).addTransaction(
                cents: cents * mode.sign,
                to: child,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RenameChildView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let child: Child
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(child: Child) {
        self.child = child
        _name = State(initialValue: child.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .focused($isNameFocused)
            }
            .navigationTitle("Rename Child")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isNameFocused = true }
            .alert("Couldn't Rename Child", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            try LedgerService(modelContext: modelContext).renameChild(child, to: name)
            KidMoneyShortcuts.updateAppShortcutParameters()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension TransactionSource {
    var displayName: String {
        switch self {
        case .manual: "Manual adjustment"
        case .siri: "Siri"
        }
    }
}

private extension Int64 {
    var magnitudeAsInt64: Int64 {
        self == .min ? .max : Swift.abs(self)
    }
}
