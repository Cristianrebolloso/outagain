import SwiftUI

/// Sheet that lets the viewer reorder and remove drinks from their catalog.
/// Accessed via the "Edit" pill next to the Custom button in the composer.
///
/// Rules:
///   - All drinks (seed + custom) can be reordered via drag handle.
///   - Any drink can be removed. Seed drinks that are removed simply
///     disappear from the list — they won't come back on next launch
///     because hydration only re-adds custom drinks. The user can
///     restore them by adding a custom drink with the same name.
///   - Changes are live — the in-memory store mutates immediately and
///     UserDefaults is updated in real time.
struct DrinkListEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                    .ignoresSafeArea()

                List {
                    ForEach(store.drinks) { drink in
                        drinkRow(drink)
                            .listRowBackground(Color.white.opacity(0.05))
                            .listRowSeparatorTint(.white.opacity(0.08))
                    }
                    .onMove { source, destination in
                        store.moveDrinks(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.removeDrink(store.drinks[index])
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
            .navigationTitle("Edit Drinks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
        }
    }

    @ViewBuilder
    private func drinkRow(_ drink: DrinkTag) -> some View {
        HStack(spacing: 14) {
            // Drink icon
            DrinkIconView(drink: drink, size: 28)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(drink.name)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)

                let seedNames = Set(SeedCatalog.drinks.map { $0.name.lowercased() })
                if !seedNames.contains(drink.name.lowercased()) {
                    Text("Custom")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(accent.opacity(0.8))
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}
