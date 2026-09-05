import SwiftUI
import SwiftData

struct ChildDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let child: Child
    @State private var errorMessage: String?

    var body: some View {
        let service = LedgerService(modelContext: modelContext)
        VStack(spacing: 24) {
            Text(MoneyFormatter.string(cents: service.balance(for: child)))
                .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())

            Button("Add $0.10") { addDime() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(child.name)
        .alert("Couldn't Save Transaction", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func addDime() {
        do {
            try LedgerService(modelContext: modelContext).addTransaction(cents: 10, to: child)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

