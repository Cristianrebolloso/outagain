import SwiftUI

/// Pushed page that lets the viewer reorder and remove drinks from their catalog.
/// Accessed through the drink picker's secondary "Edit list" action.
///
/// Rules:
///   - All drinks (seed + custom) can be reordered via drag handle.
///   - Any drink can be removed. Seed drinks that are removed simply
///     disappear from the list until the user restores them from the
///     add-drink picker in the composer.
///   - Changes are live — the in-memory store mutates immediately and
///     UserDefaults is updated in real time.
struct DrinkListEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            List {
                ForEach(store.drinks) { drink in
                    drinkRow(drink)
                        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
            .scrollIndicators(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .appSecondaryPageNavigation(title: "Edit Drinks")
        .modifier(PostDetailColumn(maximumWidth: PostDetailPresentation.sheetWidth))
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func drinkRow(_ drink: DrinkTag) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: drink.primaryHex), Color(hex: drink.secondaryHex)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                DrinkIconView(drink: drink, size: 26)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(drink.name)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !seedDrinkNames.contains(drink.name.lowercased()) {
                    Text("Custom")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(accent.opacity(0.86))
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .glassEffect(.regular.tint(Color(hex: drink.secondaryHex).opacity(0.10)), in: .rect(cornerRadius: 22))
    }

    private var seedDrinkNames: Set<String> {
        Set(SeedCatalog.drinks.map { $0.name.lowercased() })
    }
}
