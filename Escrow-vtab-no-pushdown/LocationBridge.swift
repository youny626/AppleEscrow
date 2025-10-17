//
//  LocationBridge.swift
//  EscrowApp
//
//  Created by XXX on 5/29/25.
//

import CoreLocation
import Foundation

private final class LocationHandle {
    let ts, lat, lon, acc: [Double]
    let locs: [CLLocation]
    init(
        ts: [Double],
        la: [Double],
        lo: [Double],
        ac: [Double],
        locs: [CLLocation],
    ) {
        self.ts = ts
        self.lat = la
        self.lon = lo
        self.acc = ac
        self.locs = locs
    }
}
typealias LocationPtr = OpaquePointer

@_cdecl("location_vtab_prepare")
func location_vtab_prepare(
    _ outH: UnsafeMutablePointer<LocationPtr?>!,
    _ outN: UnsafeMutablePointer<Int32>!
) -> Int32 {

    let slice = LocationBuffer.shared.snapshot()

    //    if orderFlag != 0 {
    //        slice.sort { a, b in
    //            orderFlag > 0
    //                ? a.timestamp < b.timestamp
    //                : a.timestamp > b.timestamp
    //        }
    //    }
    var ts: [Double] = []
    var lat: [Double] = []
    var lon: [Double] = []
    var acc: [Double] = []

    slice.forEach { loc in
        ts.append(loc.timestamp.timeIntervalSince1970)
        lat.append(loc.coordinate.latitude)
        lon.append(loc.coordinate.longitude)
        acc.append(loc.horizontalAccuracy)
    }

    let snap = LocationHandle(
        ts: ts,
        la: lat,
        lo: lon,
        ac: acc,
        locs: slice,
    )
    outH.pointee = LocationPtr(Unmanaged.passRetained(snap).toOpaque())
    outN.pointee = Int32(slice.count)
    return 0
}

@_cdecl("location_vtab_row")
func location_vtab_row(
    _ ptr: LocationPtr?,
    _ idx: Int32,
    _ ts: UnsafeMutablePointer<Double>!,
    _ lat: UnsafeMutablePointer<Double>!,
    _ lon: UnsafeMutablePointer<Double>!,
    _ acc: UnsafeMutablePointer<Double>!,
    _ loc: UnsafeMutablePointer<UnsafeRawPointer?>!
) {
    guard let ptr else { return }
    let s = Unmanaged<LocationHandle>.fromOpaque(UnsafeRawPointer(ptr))
        .takeUnretainedValue()
    let i = Int(idx)
    if i >= s.locs.count { return }

    ts.pointee = s.ts[i]
    lat.pointee = s.lat[i]
    lon.pointee = s.lon[i]
    acc.pointee = s.acc[i]
    loc.pointee = UnsafeRawPointer(
        Unmanaged.passRetained(s.locs[i]).toOpaque()
    )

}

@_cdecl("location_vtab_release")
func location_vtab_release(_ h: LocationPtr?) {
    if let h {
        Unmanaged<LocationHandle>.fromOpaque(UnsafeRawPointer(h)).release()
    }
}
