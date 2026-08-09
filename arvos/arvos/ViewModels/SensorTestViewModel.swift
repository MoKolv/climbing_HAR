//
//  SensorTestViewModel.swift
//  arvos
//
//  ViewModel for real-time sensor testing and visualization
//

import SwiftUI
import Combine
import CoreLocation
import ARKit
import simd

class SensorTestViewModel: ObservableObject {
    // Managers
    private let sensorManager = SensorManager.shared

    // Published state
    @Published var isRunning = false

    // Sensor toggles
    @Published var showLiDAR = true
    @Published var showCamera = true
    @Published var showIMU = true
    @Published var showPose = true
    @Published var showGPS = true
    @Published var showWatch = true

    // Latest sensor data
    @Published var latestPointCloud: PointCloud?
    @Published var latestDepthSample: DepthVisualizationSample?
    @Published var latestCameraImage: UIImage?
    @Published var latestIMU: IMUData?
    @Published var latestPose: PoseData?
    @Published var latestGPS: GPSData?
    @Published var latestWatchIMU: WatchIMUNetworkData?
    @Published var latestWatchAttitude: WatchAttitudeData?
    @Published var latestWatchActivity: WatchMotionActivityData?
    @Published var watchConnected = false
    @Published var watchHz: Double = 0

    // Metadata
    @Published var cameraResolution: String?
    @Published var lastSensorUpdate: Date?

    private var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    private func setupBindings() {
        // Observe sensor manager updates
        sensorManager.$isStreaming
            .assign(to: &$isRunning)
        
        // Observe watch connectivity
        sensorManager.watchSensorManager.$isWatchConnected
            .assign(to: &$watchConnected)
        
        sensorManager.watchSensorManager.$watchHz
            .assign(to: &$watchHz)
        
        sensorManager.watchSensorManager.$latestAttitude
            .receive(on: DispatchQueue.main)
            .sink { [weak self] attitude in
                guard let self else { return }
                self.latestWatchAttitude = attitude
                if attitude != nil && self.showWatch {
                    self.recordSensorUpdate()
                }
            }
            .store(in: &cancellables)
        
        sensorManager.watchSensorManager.$latestActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in
                guard let self else { return }
                self.latestWatchActivity = activity
                if activity != nil && self.showWatch {
                    self.recordSensorUpdate()
                }
            }
            .store(in: &cancellables)
        
    }

    func toggleTesting() {
        if isRunning {
            stopTesting()
        } else {
            startTesting()
        }
    }

    func startTesting() {
        // Set mode to full sensor for testing
        sensorManager.setMode(.fullSensor)

        // Set delegates to capture data
        sensorManager.arKitService.delegate = self
        sensorManager.cameraService.delegate = self
        sensorManager.imuService.delegate = self
        sensorManager.gpsService.delegate = self
        sensorManager.watchSensorManager.delegate = self

        // Start streaming
        sensorManager.startStreaming()

        lastSensorUpdate = nil
    }

    func stopTesting() {
        sensorManager.stopStreaming()

        // Clear data
        latestPointCloud = nil
        latestDepthSample = nil
        latestCameraImage = nil
        latestIMU = nil
        latestPose = nil
        latestGPS = nil
        latestWatchIMU = nil
        latestWatchAttitude = nil
        latestWatchActivity = nil
        cameraResolution = nil
        lastSensorUpdate = nil
    }

    private func recordSensorUpdate() {
        lastSensorUpdate = Date()
    }
}

// MARK: - ARKitServiceDelegate

extension SensorTestViewModel: ARKitServiceDelegate {
    func arKitService(_ service: ARKitService, didCapture frame: CameraFrame) {
        DispatchQueue.main.async {
            if self.showCamera {
                self.latestCameraImage = UIImage(data: frame.data)
                self.cameraResolution = "\(frame.width)×\(frame.height)"
                self.recordSensorUpdate()
            }
        }
    }

    func arKitService(_ service: ARKitService, didCapture frame: DepthFrame) {
        DispatchQueue.main.async {
            if self.showLiDAR {
                self.latestPointCloud = frame.pointCloud
                self.recordSensorUpdate()
            }
        }
    }

    func arKitService(_ service: ARKitService, didOutputDepthSample sample: DepthVisualizationSample) {
        DispatchQueue.main.async {
            if self.showLiDAR {
                self.latestDepthSample = sample
                self.recordSensorUpdate()
            }
        }
    }

    func arKitService(_ service: ARKitService, didUpdate pose: PoseData) {
        DispatchQueue.main.async {
            if self.showPose {
                self.latestPose = pose
                self.recordSensorUpdate()
            }
        }
    }

    func arKitService(_ service: ARKitService, didEncounterError error: Error) {
    }
}

// MARK: - CameraServiceDelegate

extension SensorTestViewModel: CameraServiceDelegate {
    func cameraService(_ service: CameraService, didCapture frame: CameraFrame) {
        DispatchQueue.main.async {
            if self.showCamera && !self.sensorManager.usingARKitCamera {
                self.latestCameraImage = UIImage(data: frame.data)
                self.cameraResolution = "\(frame.width)×\(frame.height)"
                self.recordSensorUpdate()
            }
        }
    }

    func cameraService(_ service: CameraService, didEncounterError error: Error) {
    }
}

// MARK: - IMUServiceDelegate

extension SensorTestViewModel: IMUServiceDelegate {
    func imuService(_ service: IMUService, didUpdate data: IMUData) {
        DispatchQueue.main.async {
            if self.showIMU {
                self.latestIMU = data
                self.recordSensorUpdate()
            }
        }
    }

    func imuService(_ service: IMUService, didEncounterError error: Error) {
    }
}

// MARK: - GPSServiceDelegate

extension SensorTestViewModel: GPSServiceDelegate {
    func gpsService(_ service: GPSService, didUpdate location: GPSData) {
        DispatchQueue.main.async {
            if self.showGPS {
                self.latestGPS = location
                self.recordSensorUpdate()
            }
        }
    }

    func gpsService(_ service: GPSService, didEncounterError error: Error) {
    }
}

// MARK: - WatchSensorManagerDelegate

extension SensorTestViewModel: WatchSensorManagerDelegate {
    func watchSensorManager(_ manager: WatchSensorManager, didReceiveIMU data: WatchIMUNetworkData) {
        DispatchQueue.main.async {
            if self.showWatch {
                self.latestWatchIMU = data
                self.recordSensorUpdate()
            }
        }
    }
    func watchSensorManager(_ manager: WatchSensorManager, didReceiveAttitude data: WatchAttitudeNetworkData){
        DispatchQueue.main.async {
            if self.showWatch {
                self.latestWatchAttitude = WatchAttitudeData(
                    quaternion: data.quaternion,
                    pitch: data.pitch,
                    roll: data.roll,
                    yaw: data.yaw,
                    referenceFrame: data.referenceFrame
                )
                self.recordSensorUpdate()
            }
        }
    }
}
