//
//  arvosWatchApp.swift
//  arvosWatchApp
//
//  Watch app entry point
//

import SwiftUI

@main
struct arvosWatchApp: App {
    @StateObject private var connectivityService = WatchConnectivityService.shared
    @State private var showSplash = true
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                WatchContentView()
                    .environmentObject(connectivityService)
                    .opacity(showSplash ? 0.0 : 1.0)

                if showSplash {
                    WatchSplashScreenView()
                        .ignoresSafeArea()
                        .transition(AnyTransition.opacity)
                        .zIndex(1)
                }
            }
            .onAppear {
                // Show splash for 3 seconds on watch (shorter than iPhone)
                let duration: Double = 3.0
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        showSplash = false
                    }
                }
            }
        }
    }
}

// MARK: - Watch Splash Screen

struct WatchSplashScreenView: View {
    @State private var opacity: Double = 0.0
    @State private var scale: CGFloat = 0.8

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // ARVOS text with animation
            VStack(spacing: 8) {
                Text("ARVOS")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .opacity(opacity)
                    .scaleEffect(scale)
            }
        }
        .onAppear {
            // Animate text appearance
            withAnimation(.easeOut(duration: 0.8)) {
                opacity = 1.0
                scale = 1.0
            }
        }
    }
}

