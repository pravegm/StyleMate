import Foundation
import CoreLocation

/// The weather's location. City-level is all the weather needs, so the app asks for
/// reduced accuracy (`NSLocationDefaultAccuracyReduced`) and kilometre precision, When In Use only.
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var locationError: CLError?
    static let shared = LocationService()
    /// `.locationUnknown` retries so far for the current request.
    private var unknownRetries = 0
    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Delay before retry `attempt` (1-based) after `.locationUnknown`: 1, 2, 4, 8, 16 s, then
    /// nil (give up and report the error, so the weather UI stops waiting).
    static func retryDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= 5 else { return nil }
        return pow(2, Double(attempt - 1))
    }

    func requestLocation() {
        unknownRetries = 0
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Do NOT call requestLocation() yet; wait for user response
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        } else {
            // Handle denied/restricted
            self.locationError = CLError(.denied)
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        unknownRetries = 0
        location = locations.first
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError {
            if clError.code == .locationUnknown {
                // Not a real failure yet (no fix so far): retry with backoff, a few times.
                unknownRetries += 1
                if let delay = Self.retryDelay(attempt: unknownRetries) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.manager.requestLocation()
                    }
                    return
                }
            }
            locationError = clError
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            unknownRetries = 0
            manager.requestLocation()
        case .denied, .restricted:
            // Propagate so the weather UI stops its loading spinner and can offer
            // a Grant/Retry affordance instead of hanging forever.
            locationError = CLError(.denied)
        default:
            break
        }
    }
}
