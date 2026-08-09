//
//  WatchSplashScreenView.swift
//  arvosWatchApp
//
//  Splash screen with video for Apple Watch
//

import SwiftUI
import AVKit

struct WatchSplashScreenView: View {
    @State private var player: AVPlayer?
    @State private var opacity: Double = 0.0
    @State private var scale: CGFloat = 0.8

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let player = player, let url = Bundle.main.url(forResource: "splash", withExtension: "mp4") {
                // Use native VideoPlayer for watchOS
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                // Fallback: Animated text
                VStack(spacing: 8) {
                    Text("ARVOS")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .opacity(opacity)
                        .scaleEffect(scale)
                }
            }
        }
        .onAppear {
            setupVideoPlayer()
            // Animate fallback text
            withAnimation(.easeOut(duration: 0.8)) {
                opacity = 1.0
                scale = 1.0
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func setupVideoPlayer() {
        // Look for splash video in bundle
        guard let videoURL = Bundle.main.url(forResource: "splash", withExtension: "mp4") else {
            #if DEBUG
            print("⚠️ Watch: Splash video not found - using fallback")
            #endif
            return
        }

        player = AVPlayer(url: videoURL)
        player?.isMuted = true
        player?.play()

        // Listen for video end
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { _ in
            // Video finished playing
        }
    }
}

#Preview {
    WatchSplashScreenView()
}

