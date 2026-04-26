import CoreLocation

/// Requests "when in use" location permission, which macOS requires before
/// CWInterface.bssid() will return a real value.
/// Call requestIfNeeded() once at launch; set onAuthorizationChange to be
/// notified when the user grants or denies the prompt.
class LocationPermissionManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermissionManager()

    private let manager = CLLocationManager()
    var onAuthorizationChange: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            onAuthorizationChange?()   // already good — notify immediately
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?()
    }
}
