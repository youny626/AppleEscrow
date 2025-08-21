//
//  LocationBuffer.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/29/25.
//

import CoreLocation

final class LocationBuffer: NSObject, CLLocationManagerDelegate {
    static let shared = LocationBuffer()

    private let mgr = CLLocationManager()
    private var buf = [CLLocation]()
    private let cap = 256
    private let lock = NSLock()

    private override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest

        mgr.requestWhenInUseAuthorization()
    }

    func locationManager(
        _ m: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        switch mgr.authorizationStatus {
        case .notDetermined:
            mgr.requestWhenInUseAuthorization()
        case .restricted:
            print("Sorry, restricted")
        case .denied:
            print("Sorry, denied")
        case .authorizedAlways, .authorizedWhenInUse:
            print("startUpdatingLocation")
            mgr.startUpdatingLocation()
            if let first = mgr.location {  // seed if still empty
                lock.lock()
                if buf.isEmpty {
                    buf.append(first)
                }
                lock.unlock()
            }
        @unknown default:
            print("Unknown status")
        }
    }

    func locationManager(
        _ m: CLLocationManager,
        didUpdateLocations locs: [CLLocation]
    ) {
        print("didUpdateLocations")
        lock.lock()
        buf.append(contentsOf: locs)
        if buf.count > cap {
            buf.removeFirst(buf.count - cap)
        }
        lock.unlock()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
//        fatalError(error.localizedDescription)
        print("Location manager failed: \(error.localizedDescription)")
    }

    func snapshot() -> [CLLocation] {
        lock.lock()
        defer { lock.unlock() }
        return buf
    }
}
