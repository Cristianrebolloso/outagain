import SwiftUI
import UIKit

struct AvatarView: View {
    let avatar: AvatarStyle
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if let imageData = avatar.imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(hex: avatar.primaryHex), Color(hex: avatar.secondaryHex)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: avatar.symbol)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
    }
}

struct AvatarPile: View {
    let avatars: [AvatarStyle]
    var size: CGFloat = 34
    var overlap: CGFloat = 12
    var limit: Int = 3

    var body: some View {
        let visible = Array(avatars.prefix(limit))
        let extraCount = max(avatars.count - visible.count, 0)

        HStack(spacing: -overlap) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, avatar in
                AvatarView(avatar: avatar, size: size)
            }

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
            }
        }
    }
}

struct MomentMediaView: View {
    let media: MomentMedia
    var height: CGFloat = 280

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let data = media.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(hex: media.primaryHex), Color(hex: media.secondaryHex)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(.white.opacity(0.13))
                    .frame(width: height * 0.55, height: height * 0.55)
                    .blur(radius: 24)
                    .offset(x: height * 0.2, y: -height * 0.1)
                VStack(alignment: .leading, spacing: 12) {
                    Spacer()
                    Image(systemName: media.symbol)
                        .font(.system(size: 34, weight: .bold))
                    Text("Captured fast")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                    Text("Camera-first placeholder moment for the MVP feed.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .foregroundStyle(.white)
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }
}

struct EmptyStateCard: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        NightPanel {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.warmGold)
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }
        }
    }
}
