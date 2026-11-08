import SwiftUI

#if canImport(SwiftUICore, _version: 8.1)
    /// Camera imagery fills its physical half; controls stay below the actual
    /// display division rather than inheriting the split style's content margins.
    @available(iOS 27.1, *)
    struct DuoTabletopCameraStyle: ArrangementViewStyle {
        func makeBody(configuration: Configuration) -> some View {
            GeometryReader { geometry in
                let division = geometry.reservedRegions(kind: .division)
                    .first { $0.frame.width > $0.frame.height }?.frame
                let upperHeight = min(geometry.size.height, max(0, division?.midY ?? geometry.size.height / 2))
                // Reserved division bounds include protective spacing. Imagery
                // reaches the hinge center; interactive controls keep their insets.
                let lowerStart = upperHeight
                VStack(spacing: 0) {
                    configuration.primary
                        .frame(width: geometry.size.width, height: upperHeight)
                        .clipped()
                    Color.clear.frame(height: lowerStart - upperHeight)
                    configuration.secondary
                        .frame(width: geometry.size.width, height: max(0, geometry.size.height - lowerStart))
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
    }
#endif
