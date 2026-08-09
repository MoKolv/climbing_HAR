//
//  SplashScreenView.swift
//  arvos
//
//  Splash screen: Video for iPhone, Black for iPad
//

import SwiftUI
import AVKit
import AVFoundation

struct SplashScreenView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: Simple black splash
            iPadSplash
        } else {
            // iPhone: Video splash
            iPhoneSplash
        }
    }

    // MARK: - iPad Splash (Black with Text)

    private var iPadSplash: some View {
        BlackSplashView()
    }

    // MARK: - iPhone Splash (Video)

    private var iPhoneSplash: some View {
        VideoSplashView()
    }
}

// MARK: - Black Splash for iPad

struct BlackSplashView: View {
    @State private var opacity = 0.0
    @State private var scale: CGFloat = 0.8

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Text("ARVOS")
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .opacity(opacity)
                .scaleEffect(scale)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                opacity = 1.0
                scale = 1.0
            }
        }
    }
}

// MARK: - Video Splash for iPhone

struct VideoSplashView: View {
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let player = player {
                VideoPlayerFillView(player: player)
                    .ignoresSafeArea()
            } else {
                // Fallback while video loads
                Text("ARVOS")
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .onAppear {
            setupVideoPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func setupVideoPlayer() {
        // Try multiple ways to find the video file
        var videoURL: URL?
        
        // Method 1: Standard bundle resource lookup (try both cases)
        videoURL = Bundle.main.url(forResource: "splash", withExtension: "mp4")
        if videoURL == nil {
            videoURL = Bundle.main.url(forResource: "Splash", withExtension: "mp4")
        }
        
        // Method 2: Direct path lookup in bundle
        if videoURL == nil, let resourcePath = Bundle.main.resourcePath {
            let possiblePaths = [
                "\(resourcePath)/splash.mp4",
                "\(resourcePath)/Splash.mp4",
                "\(resourcePath)/arvos/splash.mp4",
                "\(resourcePath)/arvos/Splash.mp4"
            ]
            
            for path in possiblePaths {
                if FileManager.default.fileExists(atPath: path) {
                    videoURL = URL(fileURLWithPath: path)
                    break
                }
            }
        }
        
        guard let videoURL = videoURL else {
            #if DEBUG
            // List available resources for debugging
            if let resourcePath = Bundle.main.resourcePath {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) {
                    let videoFiles = contents.filter { $0.lowercased().contains("splash") || $0.lowercased().hasSuffix(".mp4") }
                    if !videoFiles.isEmpty {
                    } else {
                    }
                }
            }
            #endif
            return
        }

        player = AVPlayer(url: videoURL)
        player?.isMuted = true // Mute the video
        player?.play()

        // Listen for video end to loop or stop
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { _ in
            // Video finished playing - will auto-transition via parent view
        }
    }
}

// MARK: - Custom Video Player with Fill Mode

struct VideoPlayerFillView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player
        view.playerLayer?.videoGravity = .resizeAspectFill // Fill screen, may crop
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        // Frame updates are handled automatically by the custom view
    }

    class PlayerView: UIView {
        var playerLayer: AVPlayerLayer? {
            return layer as? AVPlayerLayer
        }

        var player: AVPlayer? {
            get { playerLayer?.player }
            set { playerLayer?.player = newValue }
        }

        override class var layerClass: AnyClass {
            return AVPlayerLayer.self
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer?.frame = bounds
        }
    }
}

#Preview {
    SplashScreenView()
}
