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
        guard count > 0 else { return }
        let store = CNContactStore()
        // Use smaller batches to avoid AddressBook XPC overload at very large sizes
        let batch = 1000
        var i = 0
        while i < count {
            autoreleasepool {
                let end = min(i + batch, count)
                let req = CNSaveRequest()
                var idx = i
                while idx < end {
                    let c = CNMutableContact()
                    c.givenName =
                        idx == count - 1 ? "uniqueName" : "\(prefix)GN\(idx)"
                    c.familyName = "\(prefix)FN\(idx)"
                    let line = String(format: "%04d", idx % 10000)
                    let phone = CNLabeledValue(
                        label: CNLabelPhoneNumberMobile,
                        value: CNPhoneNumber(stringValue: "650-555-\(line)")
                    )
                    c.phoneNumbers = [phone]
                    req.add(c, toContainerWithIdentifier: nil)
                    idx += 1
                }
                _ = try? store.execute(req)
            }
            // brief yield to allow addressbookd to process
            Thread.sleep(forTimeInterval: 0.01)
            i += batch
        }
        // Enumerate to persist identifiers for faster subsequent removals
        let fetch = CNContactFetchRequest(keysToFetch: [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
        ])
        var ids: [String] = []
        try? store.enumerateContacts(with: fetch) { c, _ in
            if c.givenName.hasPrefix(prefix) || c.givenName == "uniqueName" {
                ids.append(c.identifier)
            }
        }
        if !ids.isEmpty {
            let text = ids.joined(separator: "\n")
            try? text.data(using: .utf8)?.write(to: idsFileURL)
        }
    }

    // Ensure exact benchmark contact count equals `target` by trimming only,
    // and guarantee a single 'uniqueName' contact exists.
    static func ensureExact(to target: Int) {
        let store = CNContactStore()
        let fetch = CNContactFetchRequest(keysToFetch: [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
        ])
        var escrowIds: [String] = []
        var uniqueIds: [String] = []
        try? store.enumerateContacts(with: fetch) { c, _ in
            if c.givenName == "uniqueName" {
                uniqueIds.append(c.identifier)
            } else if c.givenName.hasPrefix(prefix) {
                escrowIds.append(c.identifier)
            }
        }

        // Keep at most one uniqueName
        if uniqueIds.count > 1 {
            let extras = uniqueIds.dropFirst()
            let req = CNSaveRequest()
            extras.forEach { id in
                if let c = try? store.unifiedContact(withIdentifier: id, keysToFetch: []) {
                    let mut = c.mutableCopy() as! CNMutableContact
                    req.delete(mut)
                }
            }
            _ = try? store.execute(req)
            uniqueIds = Array(uniqueIds.prefix(1))
        }

        let desiredEscrow = max(target - 1, 0) // reserve one for uniqueName
        if escrowIds.count > desiredEscrow {
            let toRemove = escrowIds.count - desiredEscrow
            var i = 0
            let batch = 2000
            while i < toRemove {
                let end = min(i + batch, toRemove)
                let slice = escrowIds[i..<end]
                let req = CNSaveRequest()
                slice.forEach { id in
                    if let c = try? store.unifiedContact(withIdentifier: id, keysToFetch: []) {
                        let mut = c.mutableCopy() as! CNMutableContact
                        req.delete(mut)
                    }
                }
                _ = try? store.execute(req)
                i = end
            }
        }

        // Ensure uniqueName exists
        if uniqueIds.isEmpty {
            let c = CNMutableContact()
            c.givenName = "uniqueName"
            c.familyName = prefix + "FN_unique"
            let req = CNSaveRequest()
            req.add(c, toContainerWithIdentifier: nil)
            _ = try? store.execute(req)
        }
    }
}

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

    static func currentCount() -> Int {
        guard let album = ensureAlbum() else { return 0 }
        return PHAsset.fetchAssets(in: album, options: nil).count
    }

    static func ensureCount(to count: Int) {
        requestPhotosAuthIfNeeded()
        let cur = currentCount()
        if cur < count { add(count: count - cur) }
        // assuming sizes increase; if cur > count, skip to avoid unintended deletes
    }

    static func remove() {
        guard let album = ensureAlbum() else { return }
        let fetch = PHAsset.fetchAssets(in: album, options: nil)
        guard fetch.count > 0 else { return }
        // One performChanges call → one confirmation prompt regardless of count
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(fetch)
        }) { _, _ in sem.signal() }
        sem.wait()
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
        let batch = 5000
        var created = 0
        while created < count {
            let n = min(batch, count - created)
            var placeholders: [PHObjectPlaceholder] = []
            PHPhotoLibrary.shared().performChanges({
                let albumReq = PHAssetCollectionChangeRequest(for: album)
                placeholders.removeAll(keepingCapacity: true)
                placeholders.reserveCapacity(n)
                for _ in 0..<n {
                    let cr = PHAssetCreationRequest.forAsset()
                    cr.addResource(with: .photo, fileURL: srcURL, options: nil)
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

    // Delete extras so album contains at most `target` assets (one prompt per run).
    static func ensureAtMost(to target: Int) {
        requestPhotosAuthIfNeeded()
        guard let album = ensureAlbum() else { return }
        let fetch = PHAsset.fetchAssets(in: album, options: nil)
        let count = fetch.count
        guard count > target else { return }
        let toDelete = count - target
        var assetsToDelete: [PHAsset] = []
        assetsToDelete.reserveCapacity(toDelete)
        fetch.enumerateObjects { a, _, stop in
            if assetsToDelete.count < toDelete {
                assetsToDelete.append(a)
            } else {
                stop.pointee = true
            }
        }
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
        }) { _, _ in sem.signal() }
        sem.wait()
    }
}

struct BenchRunner {
    private static let baseline: String = {
        ProcessInfo.processInfo.environment["BASELINE"] ?? "unknown"
    }()
    // Run a single size per execution by default (100k). You can override with RUN_SIZE env var.
    private static let sizes: [Int] = {
        if let s = ProcessInfo.processInfo.environment["RUN_SIZE"],
            let n = Int(s)
        { return [n] }
        return [100_000]
    }()

    private static func csvURL(for size: Int) -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return docs.appendingPathComponent("bench_\(baseline)_\(size).csv")
    }

    // Current CSV target for the running size
    private static var currentCsvURL: URL?
    private static func appendCSV(_ line: String) {
        guard let url = currentCsvURL else { return }
        let header = "baseline,query,size,mean_ms,std_ms\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            // write header for a fresh file
            try? header.data(using: .utf8)?.write(to: url)
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
            "\(baseline),\(name),\(size),\(samples.mean),\(samples.std)"
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
        // Prepare CSV output for this size
        let out = csvURL(for: size)
        try? FileManager.default.removeItem(at: out)
        currentCsvURL = out
        waitForLocationReady()
        // Trim contacts/photos down to target without re-adding large amounts.
        ContactSeeder.ensureExact(to: size)
        PhotoSeeder.ensureAtMost(to: size)

        let contact = [
            ("Contacts - Full", "SELECT * FROM Contacts"),
            (
                "Contacts - Projection",
                "SELECT familyName, givenName FROM Contacts"
            ),
            (
                "Contacts - Predicate",
                "SELECT * FROM Contacts WHERE givenName = 'uniqueName'"
            ),
        ]
        let photos = [
            ("Photos - Full", "SELECT * FROM Photos"),
            ("Photos - Projection", "SELECT phasset FROM Photos"),
            (
                "Photos - Predicate",
                "SELECT * FROM Photos WHERE collectionName = 'uniqueAlbum'"
            ),
            (
                "Photos - Order By / Limit",
                "SELECT * FROM Photos ORDER BY creationDate DESC LIMIT 1"
            ),
        ]
        let loc = [
            // ("locFull", "SELECT * FROM Location"),
            // ("locProj", "SELECT location FROM Location"),
            (
                "Location - Order By / Limit",
                "SELECT * FROM Location ORDER BY timestamp DESC LIMIT 1"
            )
        ]

        contact.forEach { benchQuery(name: $0.0, sql: $0.1, size: size) }
        photos.forEach { benchQuery(name: $0.0, sql: $0.1, size: size) }
        loc.forEach { benchQuery(name: $0.0, sql: $0.1, size: size) }
        recordPreloadIfNeeded()
    }

    static func kickOff() {
        // run asynchronously so UI can finish launching
        DispatchQueue.global(qos: .userInitiated).async {
            for s in sizes {
                benchSize(s)
                if let out = currentCsvURL {
                    print("Bench finished – see CSV file in \(out.path())")
                }
            }
            // Preserve seeded data for subsequent runs
        }
    }
}
