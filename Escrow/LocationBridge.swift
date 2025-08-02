//
//  LocationBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/29/25.
//

import CoreLocation
import Foundation

private struct LocationColMask {
    static let ts: UInt = 1 << 0
    static let lat: UInt = 1 << 1
    static let lon: UInt = 1 << 2
    static let acc: UInt = 1 << 3
    static let loc: UInt = 1 << 4
}

private final class LocationHandle {
    let ts, lat, lon, acc: [Double]
    let locs: [CLLocation]
    let mask: UInt
    init(
        ts: [Double],
        la: [Double],
        lo: [Double],
        ac: [Double],
        locs: [CLLocation],
        mask: UInt
    ) {
        self.ts = ts
        self.lat = la
        self.lon = lo
        self.acc = ac
        self.locs = locs
        self.mask = mask
    }
}
typealias LocationPtr = OpaquePointer

@_cdecl("location_vtab_prepare")
func location_vtab_prepare(
    _ orderFlag: Int32, // 1 ASC, -1 DESC, 0 none
    _ limit: Int32,
    _ mask: UInt,
    _ outH: UnsafeMutablePointer<LocationPtr?>!,
    _ outN: UnsafeMutablePointer<Int32>!
) -> Int32 {

    var slice = LocationBuffer.shared.snapshot()

    //    if orderFlag != 0 {
    //        slice.sort { a, b in
    //            orderFlag > 0
    //                ? a.timestamp < b.timestamp
    //                : a.timestamp > b.timestamp
    //        }
    //    }
    if orderFlag == -1 {
//        print("order by pushdown")
        slice.reverse()
    }

    if limit > 0, slice.count > limit {
        slice.removeLast(slice.count - Int(limit))
    }

    var ts: [Double] = []
    var lat: [Double] = []
    var lon: [Double] = []
    var acc: [Double] = []
    if mask
        & (LocationColMask.ts | LocationColMask.lat | LocationColMask.lon
            | LocationColMask.acc) != 0
    {
        slice.forEach { loc in
            if mask & LocationColMask.ts != 0 {
                ts.append(loc.timestamp.timeIntervalSince1970)
            }
            if mask & LocationColMask.lat != 0 {
                lat.append(loc.coordinate.latitude)
            }
            if mask & LocationColMask.lon != 0 {
                lon.append(loc.coordinate.longitude)
            }
            if mask & LocationColMask.acc != 0 {
                acc.append(loc.horizontalAccuracy)
            }
        }
    }

    let snap = LocationHandle(
        ts: ts,
        la: lat,
        lo: lon,
        ac: acc,
        locs: slice,
        mask: mask
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

    if s.mask & LocationColMask.ts != 0 { ts.pointee = s.ts[i] }
    if s.mask & LocationColMask.lat != 0 { lat.pointee = s.lat[i] }
    if s.mask & LocationColMask.lon != 0 { lon.pointee = s.lon[i] }
    if s.mask & LocationColMask.acc != 0 { acc.pointee = s.acc[i] }
    if s.mask & LocationColMask.loc != 0 {
        loc.pointee = UnsafeRawPointer(
            Unmanaged.passRetained(s.locs[i]).toOpaque()
        )
    }
}

@_cdecl("location_vtab_release")
func location_vtab_release(_ h: LocationPtr?) {
    if let h {
        Unmanaged<LocationHandle>.fromOpaque(UnsafeRawPointer(h)).release()
    }
}
