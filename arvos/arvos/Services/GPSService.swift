//
//  GPSService.swift
//  arvos
//
//  GPS/Location service using CoreLocation
//

import Foundation
import CoreLocation
import Combine

protocol GPSServiceDelegate: AnyObject {
    func gpsService(_ service: GPSService, didUpdate location: GPSData)
    func gpsService(_ service: GPSService, didEncounterError error: Error)
}

class GPSService: NSObject {
    weak var delegate: GPSServiceDelegate?

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var targetHz: Int = 1
    private var shouldStartWhenAuthorized = false

    private var lastUpdateTime: UInt64 = 0
    private var updateInterval: UInt64 = 0

    // MARK: - Initialization

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
    }

    // MARK: - Configuration

    func configure(hz: Int, accuracy: CLLocationAccuracy = kCLLocationAccuracyBest) {
        targetHz = hz
        updateInterval = Constants.Time.nanosPerSecond / UInt64(hz)
        locationManager.desiredAccuracy = accuracy
    }

    // MARK: - Permissions

    func requestPermissions() {
        let status = locationManager.authorizationStatus

        switch status {
        case .notDetermined:
            DispatchQueue.main.async { [weak self] in
                self?.locationManager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            delegate?.gpsService(self, didEncounterError: GPSError.permissionDenied)
        case .authorizedWhenInUse, .authorizedAlways:
            // Already authorized
            break
        @unknown default:
            break
        }
    }

    var authorizationStatus: CLAuthorizationStatus {
        return locationManager.authorizationStatus
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }

        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .notDetermined:
            shouldStartWhenAuthorized = true
            DispatchQueue.main.async { [weak self] in
                self?.locationManager.requestWhenInUseAuthorization()
            }
            return
        default:
            delegate?.gpsService(self, didEncounterError: GPSError.permissionDenied)
            return
        }

        // Check if location services are enabled (do this check off main thread if possible)
        let servicesEnabled = CLLocationManager.locationServicesEnabled()
        guard servicesEnabled else {
            delegate?.gpsService(self, didEncounterError: GPSError.servicesDisabled)
            return
        }

        locationManager.startUpdatingLocation()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }

        locationManager.stopUpdatingLocation()
        isRunning = false
    }

    func updateFrequency(_ hz: Int) {
        targetHz = hz
        updateInterval = Constants.Time.nanosPerSecond / UInt64(hz)
    }

    // MARK: - High Accuracy Mode

    func enableHighAccuracy() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .otherNavigation
    }

    func disableHighAccuracy() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .other
    }
}

// MARK: - CLLocationManagerDelegate

extension GPSService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        let timestamp = Constants.Time.now()

        // Rate limiting
        guard timestamp - lastUpdateTime >= updateInterval else { return }
        lastUpdateTime = timestamp

        // Filter out invalid locations
        guard location.horizontalAccuracy >= 0 else { return }

        let gpsData = GPSData(timestamp: timestamp, location: location)
        delegate?.gpsService(self, didUpdate: gpsData)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        delegate?.gpsService(self, didEncounterError: error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        switch status {
        case .denied, .restricted:
            delegate?.gpsService(self, didEncounterError: GPSError.permissionDenied)
            shouldStartWhenAuthorized = false
            stop()
        case .authorizedWhenInUse, .authorizedAlways:
            if shouldStartWhenAuthorized {
                shouldStartWhenAuthorized = false
                start()
            }
        default:
            break
        }
    }
}

// MARK: - Errors

enum GPSError: LocalizedError {
    case permissionDenied
    case servicesDisabled
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location permission denied. Please enable in Settings."
        case .servicesDisabled:
            return "Location services are disabled on this device"
        case .locationUnavailable:
            return "Unable to determine current location"
        }
    }
}
