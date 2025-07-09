import CoreLocation

final class LocationBuffer: NSObject, CLLocationManagerDelegate {
    static let shared = LocationBuffer()

    private let mgr = CLLocationManager()

    private override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest

        mgr.requestWhenInUseAuthorization()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        switch status {
        case .notDetermined:
            mgr.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            mgr.startUpdatingLocation()
            if let first = mgr.location {
                _ = Escrow.shared.insertLocation(first)
            }
        case .restricted:
            print("Location access restricted")
        case .denied:
            print("Location access denied")
        @unknown default:
            break
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        locations.forEach { Escrow.shared.insertLocation($0) }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        print("Location manager failed: \(error.localizedDescription)")
    }
}
