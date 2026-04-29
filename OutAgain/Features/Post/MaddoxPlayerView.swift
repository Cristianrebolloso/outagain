import AVFoundation
import SwiftUI

// MARK: - Maddox Easter Egg Player

/// Full-screen music player easter egg that fires when the user posts
/// a "Maddox" custom drink. Styled to match the app's liquid glass design
/// language, using the user's chosen accent color throughout.
struct MaddoxPlayerView: View {
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var volume: Float = 1.0
    @State private var timer: Timer?
    @State private var artScale: CGFloat = 1.0
    @State private var artRotation: Double = 0.0
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Background — mirrors AmbientBackground feel but tinted to accent
            Rectangle()
                .fill(.black)
                .ignoresSafeArea()

            // Soft accent glow behind artwork
            Circle()
                .fill(accent.opacity(0.35))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(y: -60)

            Circle()
                .fill(accent.opacity(0.20))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -80, y: 120)

            VStack(spacing: 0) {
                // Dismiss handle
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 36, height: 4)
                    .padding(.top, 14)
                    .padding(.bottom, 28)

                // Album artwork
                artworkView
                    .padding(.bottom, 36)

                // Song info
                songInfoView
                    .padding(.bottom, 28)

                // Scrubber
                scrubberView
                    .padding(.horizontal, 28)
                    .padding(.bottom, 32)

                // Transport controls
                transportView
                    .padding(.bottom, 32)

                // Volume slider
                volumeView
                    .padding(.horizontal, 28)
                    .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            setupPlayer()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65).delay(0.1)) {
                appeared = true
            }
        }
        .onDisappear {
            tearDown()
        }
    }

    // MARK: - Subviews

    private var artworkView: some View {
        ZStack {
            // Liquid glass frame with accent tint
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(accent.opacity(0.18))
                .frame(width: 270, height: 270)
                .blur(radius: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [accent.opacity(0.6), .white.opacity(0.15), accent.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: accent.opacity(0.45), radius: 30, x: 0, y: 12)

            Image("CuteMaddox")
                .resizable()
                .scaledToFill()
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .scaleEffect(appeared ? artScale : 0.6)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: artScale)
        // Subtle breathing animation when playing
        .onChange(of: isPlaying) { _, playing in
            if playing {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    artScale = 1.04
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    artScale = 1.0
                }
            }
        }
    }

    private var songInfoView: some View {
        VStack(spacing: 6) {
            Text("How Deep Is Your Love")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.easeOut(duration: 0.4).delay(0.15), value: appeared)

            HStack(spacing: 6) {
                // Accent dot — matches Apple Music's artist pill style
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)

                Text("Maddox")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(.easeOut(duration: 0.4).delay(0.22), value: appeared)
        }
        .padding(.horizontal, 28)
    }

    private var scrubberView: some View {
        VStack(spacing: 8) {
            // Track bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(height: 4)

                    // Filled portion
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent, accent.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: duration > 0
                                ? geo.size.width * CGFloat(currentTime / duration)
                                : 0,
                            height: 4
                        )
                }
                .frame(height: 4)
                .contentShape(Rectangle().size(CGSize(width: geo.size.width, height: 32)).offset(y: -14))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let ratio = max(0, min(1, value.location.x / geo.size.width))
                            currentTime = ratio * duration
                            player?.currentTime = currentTime
                        }
                )
            }
            .frame(height: 4)

            // Time labels
            HStack {
                Text(timeString(currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))

                Spacer()

                Text("-\(timeString(max(0, duration - currentTime)))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.28), value: appeared)
    }

    private var volumeView: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            Slider(value: $volume, in: 0...1) { _ in
                player?.volume = volume
            }
            .tint(accent)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.36), value: appeared)
    }

    private var transportView: some View {
        HStack(spacing: 44) {
            // Rewind
            transportButton(symbol: "backward.fill", size: 22) {
                player?.currentTime = 0
                currentTime = 0
            }

            // Play / Pause — liquid glass capsule, accent-filled
            Button {
                togglePlayback()
            } label: {
                ZStack {
                    // Glass backing
                    Circle()
                        .fill(accent.opacity(0.22))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Circle()
                                .strokeBorder(accent.opacity(0.55), lineWidth: 1.5)
                        )
                        .shadow(color: accent.opacity(0.4), radius: 16, x: 0, y: 6)

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: isPlaying ? 0 : 2) // optical centering for play icon
                }
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(accent.opacity(0.3)).interactive(), in: .circle)

            // Fast-forward
            transportButton(symbol: "forward.fill", size: 22) {
                guard duration > 0 else { return }
                player?.currentTime = min(duration - 0.1, (player?.currentTime ?? 0) + 10)
                currentTime = player?.currentTime ?? currentTime
            }
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.32), value: appeared)
    }

    private func transportButton(symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Audio Engine

    private func setupPlayer() {
        guard let url = Bundle.main.url(forResource: "HowDeepIsYourLove", withExtension: "mp3") else {
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.volume = volume
            duration = player?.duration ?? 0

            // Auto-play on appear
            player?.play()
            isPlaying = true
            startTimer()
        } catch {
            // Silently fail — easter egg, not critical path
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            currentTime = player?.currentTime ?? 0
            if !(player?.isPlaying ?? false) && currentTime >= duration - 0.1 {
                isPlaying = false
                timer?.invalidate()
            }
        }
    }

    private func tearDown() {
        timer?.invalidate()
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let t = max(0, Int(t))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
