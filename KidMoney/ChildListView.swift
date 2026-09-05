import SwiftUI
import SwiftData

struct ChildListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Child> { !$0.isArchived }, sort: \Child.sortOrder) private var children: [Child]
    @State private var isShowingAddChild = false

    var body: some View {
        NavigationStack {
            Group {
                if children.isEmpty {
                    ContentUnavailableView {
                        Label("No Children Yet", systemImage: "person.2")
                    } description: {
                        Text("Add your children, then use Siri to add or subtract money.")
                    } actions: {
                        Button("Add Child") { isShowingAddChild = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(children) { child in
                        NavigationLink(value: child) {
                            ChildRow(child: child)
                        }
                    }
                }
            }
            .navigationTitle("Kid Money")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Child", systemImage: "plus") { isShowingAddChild = true }
                }
            }
            .navigationDestination(for: Child.self) { child in
                ChildDetailView(child: child)
            }
            .sheet(isPresented: $isShowingAddChild) {
                AddChildView()
            }
        }
    }
}

private struct ChildRow: View {
    let child: Child

    var body: some View {
        HStack {
            Text(child.name)
            Spacer()
            Text(MoneyFormatter.string(cents: child.transactions.reduce(0) { $0 + $1.amountCents }))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

