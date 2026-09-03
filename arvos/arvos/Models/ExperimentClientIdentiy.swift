// helps distinguish different phones functioning as arvos clients

import Foundation


enum ExperimentClientRole: String, CaseIterable, Identifiable {
    case imuWatch = "imu_watch"
    case video = "video"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .imuWatch: return "IMU + Watch Phone"
        case .video: return "Video Phone"
        }
    }
}

enum ExperimentClientIdentity {
    private static let roleKey = "arvos.experiment_client_role"
    private static let installationIDKey = "arvos.installation_id"
    
    static var role: ExperimentClientRole {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: roleKey),
                  let role = ExperimentClientRole(rawValue: rawValue)
            else {
                return .imuWatch
            }
            return role
        }
        set {UserDefaults.standard.set(newValue.rawValue, forKey: roleKey)}
    }
    
    static var installaionID: String {
        if let existingID = UserDefaults.standard.string(forKey: installationIDKey) {
            return existingID
        }
        
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: installationIDKey)
        return newID
    }
}


