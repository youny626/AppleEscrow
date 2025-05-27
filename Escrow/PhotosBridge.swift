//
//  PhotosBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/23/25.
//

import Foundation
import Photos

/* bit-mask (must match photos_vtab.c) */
private struct PhotosColMask {
    static let id: UInt = 1 << 0
    static let mtype: UInt = 1 << 1
    static let date: UInt = 1 << 2
    static let cid: UInt = 1 << 3
    static let cname: UInt = 1 << 4
    static let asset: UInt = 1 << 5
}

/* snapshot handed back to C */
private final class PhotosHandle {
    let ids, cids, cns: [String]
    let types: [Int]
    let dates: [Double]
    let assets: [PHAsset]
    let mask: UInt
    init(
        ids: [String],
        t: [Int],
        d: [Double],
        cids: [String],
        cns: [String],
        a: [PHAsset],
        m: UInt
    ) {
        self.ids = ids
        self.cids = cids
        self.cns = cns
        self.types = t
        self.dates = d
        self.assets = a
        self.mask = m
    }
}
typealias PhotosPtr = OpaquePointer
private func dup(_ s: String) -> UnsafePointer<CChar>? {
    strdup(s).map { UnsafePointer($0) }
}

/* ---------------------------------------------------------------------- */
@_cdecl("photos_vtab_prepare")
func photos_vtab_prepare(
    _ idEq: UnsafePointer<CChar>?,
    _ mtEq: Int32,
    _ cidEq: UnsafePointer<CChar>?,
    _ cnameEq: UnsafePointer<CChar>?,
    _ orderFlag: Int32,
    _ limit: Int32,
    _ mask: UInt,
    _ outH: UnsafeMutablePointer<PhotosPtr?>!,
    _ outCnt: UnsafeMutablePointer<Int32>!
) -> Int32 {

    let id = idEq.flatMap { String(cString: $0) }
    let collId = cidEq.flatMap { String(cString: $0) }
    let collName = cnameEq.flatMap { String(cString: $0) }

    /* build fetch options */
    let opts = PHFetchOptions()
    if mtEq >= 0 {
        opts.predicate = NSPredicate(format: "mediaType == %d", mtEq)
    }
    if orderFlag != 0 {
        opts.sortDescriptors = [
            NSSortDescriptor(
                key: "creationDate",
                ascending: orderFlag > 0
            )
        ]
    }
    if limit > 0 {
        print("photos fetch limit = \(limit)")
        opts.fetchLimit = Int(limit)
    }

    func firstAlbum(named n: String) -> PHAssetCollection? {
        let fo = PHFetchOptions()
        fo.predicate = NSPredicate(format: "localizedTitle == %@", n)
        return
            PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .any, options: fo)
            .firstObject
    }

    /* choose fetch method */
    let fetch: PHFetchResult<PHAsset>
    if let id = id {
        print("Fetching asset id = \(id) with options \(opts.debugDescription)")
        fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: opts)
    } else if let cid = collId,
        let coll =
            PHAssetCollection
            .fetchAssetCollections(withLocalIdentifiers: [cid], options: nil)
            .firstObject
    {
        print(
            "Fetching album id = \(cid) with options \(opts.debugDescription)"
        )
        fetch = PHAsset.fetchAssets(in: coll, options: opts)
    } else if let n = collName, let coll = firstAlbum(named: n) {
        print(
            "Fetching album name = \(n) with options \(opts.debugDescription)"
        )
        fetch = PHAsset.fetchAssets(in: coll, options: opts)
    } else {
        print("Fetching assets with options \(opts.debugDescription)")
        fetch = PHAsset.fetchAssets(with: opts)
    }

    /* materialise snapshot ------------------------------------------------*/
    var ids: [String] = []
    var types: [Int] = []
    var dates: [Double] = []
    var cids: [String] = []
    var cns: [String] = []
    var assets: [PHAsset] = []

    fetch.enumerateObjects { asset, _, _ in
        ids.append(asset.localIdentifier)
        types.append(asset.mediaType.rawValue)
        dates.append(asset.creationDate?.timeIntervalSince1970 ?? 0)

        if mask & (PhotosColMask.cid | PhotosColMask.cname) != 0 {
            let colls =
                PHAssetCollection
                .fetchAssetCollectionsContaining(
                    asset,
                    with: .album,
                    options: nil
                )
            cids.append(colls.firstObject?.localIdentifier ?? "")
            cns.append(colls.firstObject?.localizedTitle ?? "")
        } else {
            cids.append("")
            cns.append("")
        }
        assets.append(asset)  // keep row alignment
    }

    let snap = PhotosHandle(
        ids: ids,
        t: types,
        d: dates,
        cids: cids,
        cns: cns,
        a: assets,
        m: mask
    )
    outH.pointee = PhotosPtr(Unmanaged.passRetained(snap).toOpaque())
    outCnt.pointee = Int32(ids.count)
    return 0
}

/* ---------------------------------------------------------------------- */
@_cdecl("photos_vtab_row")
func photos_vtab_row(
    _ h: PhotosPtr?,
    _ idx: Int32,
    _ id: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ typ: UnsafeMutablePointer<Int32>!,
    _ dat: UnsafeMutablePointer<Double>!,
    _ cid: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ cname: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ asset: UnsafeMutablePointer<UnsafeRawPointer?>!
) {
    guard let h else { return }
    let s = Unmanaged<PhotosHandle>.fromOpaque(UnsafeRawPointer(h))
        .takeUnretainedValue()
    let i = Int(idx)
    if i >= s.ids.count { return }

    if s.mask & PhotosColMask.id != 0 { id.pointee = dup(s.ids[i]) }
    if s.mask & PhotosColMask.mtype != 0 { typ.pointee = Int32(s.types[i]) }
    if s.mask & PhotosColMask.date != 0 { dat.pointee = s.dates[i] }
    if s.mask & PhotosColMask.cid != 0 { cid.pointee = dup(s.cids[i]) }
    if s.mask & PhotosColMask.cname != 0 { cname.pointee = dup(s.cns[i]) }
    if s.mask & PhotosColMask.asset != 0 {
        asset.pointee = UnsafeRawPointer(
            Unmanaged.passRetained(s.assets[i]).toOpaque()
        )  // ← FIX
    }
}

/* ---------------------------------------------------------------------- */
@_cdecl("photos_vtab_release")
func photos_vtab_release(_ h: PhotosPtr?) {
    if let h {
        Unmanaged<PhotosHandle>.fromOpaque(UnsafeRawPointer(h)).release()
    }
}
