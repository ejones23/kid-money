import SwiftUI
import SwiftData

struct ChildListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Child> { !$0.isArchived }, sort: \Child.sortOrder) private var children: [Child]
    @State private var isShowingAddChild = false
    @State private var invitationNotice = CloudLedgerInvitationNotice.shared

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
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        FamilyLedgerSharingView()
                    } label: {
                        Label("Sharing", systemImage: "person.2")
                    }
                }
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
}

private struct ChildRow: View {
    let child: Child

    var body: some View {
        let balance = MoneyFormatter.string(cents: child.transactions.reduce(0) { $0 + $1.amountCents })
        HStack {
            Text(child.name)
            Spacer()
            Text(balance)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(child.name), balance \(balance)")
    }
}
