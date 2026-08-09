//
//  MainTabView.swift
//  arvos
//
//  Main tab navigation
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var viewModel = StreamingViewModel()

    var body: some View {
        TabView {
            // Stream Tab
            NavigationStack {
                StreamView()
                    .navigationBarTitleDisplayMode(.inline)
                    .environmentObject(viewModel)
            }
            .tabItem {
                Label("Stream", systemImage: "video.circle.fill")
            }

            // Sensor Test Tab (Single integrated view)
            SensorTestView()
                .tabItem {
                    Label("Test", systemImage: "waveform.path.ecg")
                }

            // Files Tab
            FilesView()
                .tabItem {
                    Label("Files", systemImage: "folder.fill")
                }

            // Settings Tab (includes diagnostics)
            SettingsView()
                .environmentObject(viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}

#Preview {
    MainTabView()
}
