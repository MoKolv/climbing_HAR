//
//  WatchContentView.swift
//  arvosWatchApp
//
//  Main watch interface for sensor streaming control
//

import SwiftUI
import CoreMotion

struct WatchContentView: View {
    @EnvironmentObject var connectivityService: WatchConnectivityService
    @StateObject private var sensorService = WatchSensorService()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    // Connection status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectivityService.isPhoneReachable ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(connectivityService.isPhoneReachable ? "Connected" : "Disconnected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)

                    // Streaming control
                    Button(action: {
                        if sensorService.isStreaming {
                            sensorService.stopStreaming()
                        } else {
                            sensorService.startStreaming()
                        }
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: sensorService.isStreaming ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 50))
                            Text(sensorService.isStreaming ? "Stop" : "Start")
                                .font(.headline)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(sensorService.isStreaming ? .red : .green)
                
                    if sensorService.isStreaming {
                        // Stats
                        VStack(spacing: 8) {
                            HStack {
                                Text("\(String(format: "%.0f", sensorService.currentHz)) Hz")
                                    .font(.title3.bold())
                                Spacer()
                                Text("\(sensorService.sampleCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let activity = sensorService.latestActivity {
                                Divider()
                                HStack {
                                    Text(activityDescription(activity))
                                        .font(.caption.bold())
                                    Spacer()
                                    Text(confidenceString(activity.confidence))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("ARVOS")
        }
    }
    
    private func formatAngle(_ value: Double) -> String {
        let degrees = value * 180 / .pi
        return String(format: "%.1f°", degrees)
    }
    
    private func confidenceString(_ raw: Int) -> String {
        switch raw {
        case CMMotionActivityConfidence.low.rawValue:
            return "Low"
        case CMMotionActivityConfidence.medium.rawValue:
            return "Medium"
        case CMMotionActivityConfidence.high.rawValue:
            return "High"
        default:
            return "Unknown"
        }
    }
    
    private func activityDescription(_ activity: WatchMotionActivityData) -> String {
        if activity.isRunning { return "Running" }
        if activity.isWalking { return "Walking" }
        if activity.isCycling { return "Cycling" }
        if activity.isDriving { return "In Vehicle" }
        if activity.isStationary { return "Stationary" }
        return "Unknown"
    }
}

#Preview {
    WatchContentView()
        .environmentObject(WatchConnectivityService.shared)
}

