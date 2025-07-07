//
//  PhotosBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/23/25.
//

import Foundation
import Photos

private final class PhotosHandle {
    let ids, collectionIds, collectionNames: [String]
    let types: [Int]
    let dates: [Double]
    let assets: [PHAsset]
    init(
        ids: [String],
        types: [Int],
        dates: [Double],
        collectionIds: [String],
        collectionNames: [String],
        assets: [PHAsset],
    ) {
        self.ids = ids
        self.types = types
        self.dates = dates
        self.collectionIds = collectionIds
        self.collectionNames = collectionNames
        self.assets = assets
    }
}
typealias PhotosPtr = OpaquePointer
private func dup(_ s: String) -> UnsafePointer<CChar>? {
    strdup(s).map { UnsafePointer($0) }
}

@_cdecl("photos_vtab_prepare")
func photos_vtab_prepare(
    _ outH: UnsafeMutablePointer<PhotosPtr?>!,
    _ outCnt: UnsafeMutablePointer<Int32>!
) -> Int32 {

    let opts = PHFetchOptions()
    let fetch: PHFetchResult<PHAsset> = PHAsset.fetchAssets(with: opts)

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

        let colls =
            PHAssetCollection
            .fetchAssetCollectionsContaining(
                asset,
                with: .album,
                options: nil
            )
        cids.append(colls.firstObject?.localIdentifier ?? "")
        cns.append(colls.firstObject?.localizedTitle ?? "")

        assets.append(asset)  // keep row alignment
    }

    let snap = PhotosHandle(
        ids: ids,
        types: types,
        dates: dates,
        collectionIds: cids,
        collectionNames: cns,
        assets: assets,
    )
    outH.pointee = PhotosPtr(Unmanaged.passRetained(snap).toOpaque())
    outCnt.pointee = Int32(ids.count)
    return 0
}

@_cdecl("photos_vtab_row")
func photos_vtab_row(
    _ ptr: PhotosPtr?,
    _ idx: Int32,
    _ id: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ typ: UnsafeMutablePointer<Int32>!,
    _ dat: UnsafeMutablePointer<Double>!,
    _ cid: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ cname: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ asset: UnsafeMutablePointer<UnsafeRawPointer?>!
) {
    guard let ptr else { return }
    let s = Unmanaged<PhotosHandle>.fromOpaque(UnsafeRawPointer(ptr))
        .takeUnretainedValue()
    let i = Int(idx)
    if i >= s.ids.count { return }

    id.pointee = dup(s.ids[i])
    typ.pointee = Int32(s.types[i])
    dat.pointee = s.dates[i]
    cid.pointee = dup(s.collectionIds[i])
    cname.pointee = dup(s.collectionNames[i])

    asset.pointee = UnsafeRawPointer(
        Unmanaged.passRetained(s.assets[i]).toOpaque()
    )
}

@_cdecl("photos_vtab_release")
func photos_vtab_release(_ h: PhotosPtr?) {
    if let h {
        Unmanaged<PhotosHandle>.fromOpaque(UnsafeRawPointer(h)).release()
    }
}
