import Contacts
import CoreLocation
import Foundation
import Photos

private struct NanoTimer {
    private var startNs: UInt64 = 0
    mutating func start() { startNs = DispatchTime.now().uptimeNanoseconds }
    func stopMs() -> Double {
        let diff = DispatchTime.now().uptimeNanoseconds - startNs
        return Double(diff) / 1_000_000.0
    }
}

extension Array where Element == Double {
    fileprivate var mean: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
    fileprivate var std: Double {
        guard !isEmpty else { return 0 }
        let m = mean
        return sqrt(map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count))
    }
}

private enum ContactSeeder {
    static let prefix = "EscrowBench_"
    private static var idsFileURL: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return docs.appendingPathComponent("bench_contact_ids.txt")
    }

    static func reset(to count: Int) {
        remove()
        add(count: count)
    }

    private static func remove() {
        let store = CNContactStore()
        var ids: [String] = []
        if let data = try? Data(contentsOf: idsFileURL),
            let text = String(data: data, encoding: .utf8)
        {
            ids = text.split(separator: "\n").map { String($0) }
        } else {
            let fetch = CNContactFetchRequest(keysToFetch: [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
            ])
            try? store.enumerateContacts(with: fetch) { c, _ in
                if c.givenName.hasPrefix(prefix) || c.givenName == "uniqueName"
                {
                    ids.append(c.identifier)
                }
            }
        }
        guard !ids.isEmpty else { return }
        let batch = 2000
        var i = 0
        while i < ids.count {
            let end = min(i + batch, ids.count)
            let slice = ids[i..<end]
            let req = CNSaveRequest()
            slice.forEach { id in
                if let c = try? store.unifiedContact(
                    withIdentifier: id,
                    keysToFetch: []
                ) {
                    let mut = c.mutableCopy() as! CNMutableContact
                    req.delete(mut)
                }
            }
            _ = try? store.execute(req)
            i = end
        }
        try? FileManager.default.removeItem(at: idsFileURL)
    }

    private static func add(count: Int) {
        let store = CNContactStore()
        let req = CNSaveRequest()
        var ids: [String] = []
        for i in 0..<count {
            let c = CNMutableContact()
            c.givenName = i == count - 1 ? "uniqueName" : "\(prefix)GN\(i)"
            c.familyName = "\(prefix)FN\(i)"
            let line = String(format: "%04d", i % 10000)
            let phone = CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: "650-555-\(line)")
            )
            c.phoneNumbers = [phone]
            req.add(c, toContainerWithIdentifier: nil)
            ids.append(c.identifier)
        }
        if (try? store.execute(req)) != nil {
            let text = ids.filter { !$0.isEmpty }.joined(separator: "\n")
            try? text.data(using: .utf8)?.write(to: idsFileURL)
        }
    }
}

// MARK: - Seed Photos
private enum PhotoSeeder {
    static let albumName = "EscrowBench_Album"

    private static func requestPhotosAuthIfNeeded() {
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in sem.signal()
        }
        sem.wait()
    }

    private static func ensureAlbum() -> PHAssetCollection? {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var album: PHAssetCollection?
        fetch.enumerateObjects { c, _, stop in
            if c.localizedTitle == albumName {
                album = c
                stop.pointee = true
            }
        }
        if album != nil { return album }
        var ph: PHObjectPlaceholder?
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges({
            let r =
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: albumName
                )
            ph = r.placeholderForCreatedAssetCollection
        }) { _, _ in sem.signal() }
        sem.wait()
        guard let ph else { return nil }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [ph.localIdentifier],
            options: nil
        ).firstObject
    }

    static func reset(to count: Int) {
        requestPhotosAuthIfNeeded()
        remove()
        if count > 0 { add(count: count) }
    }

    static func remove() {
        guard let album = ensureAlbum() else { return }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        let sem = DispatchSemaphore(value: 0)
        let batch = 500
        var i = 0
        while i < list.count {
            let end = min(i + batch, list.count)
            let slice = list[i..<end]
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(NSArray(array: Array(slice)))
            }) { _, _ in sem.signal() }
            sem.wait()
            i = end
        }
    }

    static func add(count: Int) {
        guard let album = ensureAlbum() else { return }
        guard
            let srcPath = ProcessInfo.processInfo.environment[
                "PHOTO_SOURCE_PATH"
            ], !srcPath.isEmpty
        else {
            fatalError("PHOTO_SOURCE_PATH not set")
        }
        var srcURL = URL(fileURLWithPath: srcPath)
        if !FileManager.default.fileExists(atPath: srcURL.path) {
            // Try resolving relative to Pictures directory if sandbox blocks absolute path
            if let pics = FileManager.default.urls(
                for: .picturesDirectory,
                in: .userDomainMask
            ).first {
                let candidate = pics.appendingPathComponent(srcPath)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    srcURL = candidate
                }
            }
        }
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            fatalError("PHOTO_SOURCE_PATH does not exist: \(srcURL.path)")
        }
        let sem = DispatchSemaphore(value: 0)
        let batch = 200
        var created = 0
        while created < count {
            let n = min(batch, count - created)
            var placeholders: [PHObjectPlaceholder] = []
            PHPhotoLibrary.shared().performChanges({
                let albumReq = PHAssetCollectionChangeRequest(for: album)
                placeholders.removeAll(keepingCapacity: true)
                placeholders.reserveCapacity(n)
                let imgData = try? Data(contentsOf: srcURL)
                if imgData == nil {
                    fatalError("Cannot read PHOTO_SOURCE_PATH: \(srcURL.path)")
                }
                for _ in 0..<n {
                    let cr = PHAssetCreationRequest.forAsset()
                    cr.addResource(with: .photo, data: imgData!, options: nil)
                    if let ph = cr.placeholderForCreatedAsset {
                        placeholders.append(ph)
                    }
                }
                if placeholders.count != n {
                    fatalError(
                        "Failed to stage all photo creations: staged=\(placeholders.count) of n=\(n)"
                    )
                }
                albumReq?.addAssets(NSArray(array: placeholders))
            }) { ok, err in
                if !ok {
                    fatalError(
                        "PHPhotoLibrary performChanges failed: \(err?.localizedDescription ?? "unknown error")"
                    )
                }
                sem.signal()
            }
            sem.wait()
            created += n
        }
    }
}

struct BenchRunner {
    private static let dataSize: Int =
        Int(ProcessInfo.processInfo.environment["SIZE"] ?? "100") ?? 100
    private static let baseline: String = {
        ProcessInfo.processInfo.environment["BASELINE"] ?? "unknown"
    }()

    private static func csvURL() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return docs.appendingPathComponent("bench_\(baseline)_\(dataSize).csv")
    }

    private static let url = csvURL()

    private static var initialized = false
    private static func appendCSV(_ line: String) {
        let header = "baseline,query,size,mean_ms,std_ms\n"
        if !initialized {
            // overwrite existing file
            try? FileManager.default.removeItem(at: url)
            try? header.data(using: .utf8)?.write(to: url)
            initialized = true
        }
        if let data = (line + "\n").data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                _ = try? fh.seekToEnd()
                fh.write(data)
                try? fh.close()
            }
        }
    }

    private static func timeQuery(_ sql: String) -> Double {
        var t = NanoTimer()
        t.start()
        Escrow.shared.run(access: sql) { _ in }
        return t.stopMs()
    }

    private static func benchQuery(name: String, sql: String, size: Int) {
        _ = timeQuery(sql)  // warm-up
        var samples: [Double] = []
        for _ in 0..<10 {
            samples.append(timeQuery(sql))
        }
        appendCSV(
            "\(baseline),\(name),\(dataSize),\(samples.mean),\(samples.std)"
        )
        print("→ \(name) size \(size) : \(samples.mean) ms ± \(samples.std)")
    }

    private static var preloadRecorded = false

    private static func recordPreloadIfNeeded() {
        guard !preloadRecorded, baseline == "preload" else { return }
        for (k, v) in Escrow.preloadMetrics {
            appendCSV("\(baseline),preload_\(k),0,\(v),0")
        }
        preloadRecorded = true
    }

    // Wait for LocationBuffer to have at least one location before running location benchmarks.
    private static func waitForLocationReady(timeout: TimeInterval = 30) {
        // Ensure Escrow (and LocationBuffer) initialised on main thread
        DispatchQueue.main.sync {
            _ = Escrow.shared
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !LocationBuffer.shared.snapshot().isEmpty { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        print(
            "Warning: Location data not ready after \(timeout)s; proceeding anyway"
        )
    }

    private static func benchSize(_ size: Int) {
        print("\n=== Benchmark size = \(size) ===")
        waitForLocationReady()
        ContactSeeder.reset(to: size)
        PhotoSeeder.reset(to: size)

        let contact = [
            ("contactFull", "SELECT * FROM Contacts"),
            ("contactProj", "SELECT familyName, givenName FROM Contacts"),
            (
                "contactPred",
                "SELECT * FROM Contacts WHERE givenName = 'uniqueName'"
            ),
        ]
        let photos = [
            ("photoFull", "SELECT * FROM Photos"),
            ("photoProj", "SELECT phasset FROM Photos"),
            (
                "photoPred",
                "SELECT * FROM Photos WHERE collectionName = 'uniqueAlbum'"
            ),
            (
                "photoOrder",
                "SELECT * FROM Photos ORDER BY creationDate DESC LIMIT 1"
            ),
        ]
        let loc = [
            ("locFull", "SELECT * FROM Location"),
            ("locProj", "SELECT location FROM Location"),
            (
                "locOrder",
                "SELECT * FROM Location ORDER BY timestamp DESC LIMIT 1"
            ),
        ]

        contact.forEach { benchQuery(name: $0.0, sql: $0.1, size: size) }
        photos.forEach { benchQuery(name: $0.0, sql: $0.1, size: size) }
        loc.forEach { benchQuery(name: $0.0, sql: $0.1, size: size) }
        recordPreloadIfNeeded()

        ContactSeeder.reset(to: 0)  // clean
        PhotoSeeder.reset(to: 0)
    }

    static func kickOff() {
        // run asynchronously so UI can finish launching
        DispatchQueue.global(qos: .userInitiated).async {
            benchSize(dataSize)
            print("Bench finished – see CSV file in \(url.path())")
        }
    }
}
