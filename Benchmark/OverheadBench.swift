import Contacts
import CoreLocation
import Foundation
import Photos

#if canImport(AppKit)
    import AppKit
#endif

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

private struct Utils {
    /// Validate US phone numbers per NANP rules (basic):
    /// 1. Remove all non-digit characters and optional leading country code "1".
    /// 2. Must have exactly 10 digits afterwards.
    /// 3. Area code and central office code cannot start with 0 or 1.
    static func isValidUSPhone(_ number: String) -> Bool {
        var digits = number.filter { $0.isNumber }
        if digits.first == "1" && digits.count == 11 {
            digits.removeFirst()
        }
        guard digits.count == 10 else { return false }
        let areaFirst = digits.first!
        let centralFirst = digits[digits.index(digits.startIndex, offsetBy: 3)]
        guard areaFirst >= "2" && areaFirst <= "9" else { return false }
        guard centralFirst >= "2" && centralFirst <= "9" else { return false }
        return true
    }

    #if canImport(AppKit)
        static func image(from asset: PHAsset) -> NSImage? {
            let mgr = PHImageManager.default()
            let opts = PHImageRequestOptions()
            opts.isSynchronous = true
            opts.deliveryMode = .highQualityFormat
            var img: NSImage?
            mgr.requestImageDataAndOrientation(for: asset, options: opts) {
                data,
                _,
                _,
                _ in
                if let d = data {
                    img = NSImage(data: d)
                }
            }
            return img
        }
    #else
        // For iOS fallback – skip actual image conversion to avoid UIKit dependency
        static func image(from asset: PHAsset) -> Any? { asset }
    #endif

    static func weatherForLocation(_ loc: CLLocation) -> Double? {
        guard let apiKey = ProcessInfo.processInfo.environment["OWM_API_KEY"]
        else {
            print("OpenWeatherMap API key missing (OWM_API_KEY)")
            return nil
        }
        //        print(loc.debugDescription)
        let urlStr =
            "https://api.openweathermap.org/data/2.5/weather?lat=\(loc.coordinate.latitude)&lon=\(loc.coordinate.longitude)&appid=\(apiKey)&units=metric"
        //        print(urlStr)
        guard let url = URL(string: urlStr) else {
            fatalError("\(urlStr) is not valid")
        }
        let sem = DispatchSemaphore(value: 0)
        var temp: Double?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { sem.signal() }
            guard let data = data else {
                fatalError("openweathermap did not return data")
            }
            if let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
            {
                //                print(json)
                if let main = json["main"] as? [String: Any],
                    let t = main["temp"] as? Double
                {
                    temp = t
                }
            }
        }.resume()
        sem.wait()
        return temp
    }
}

private enum ContactSeeder {
    static let prefix = "EscrowBench_"

    static func reset(to count: Int) {
        remove()
        add(count: count)
    }

    private static func remove() {
        let store = CNContactStore()
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
        guard !ids.isEmpty else { return }
        let req = CNSaveRequest()
        ids.forEach { id in
            if let c = try? store.unifiedContact(
                withIdentifier: id,
                keysToFetch: []
            ) {
                let mut = c.mutableCopy() as! CNMutableContact
                req.delete(mut)
            }
        }
        try? store.execute(req)
    }

    private static func add(count: Int) {
        let store = CNContactStore()
        let req = CNSaveRequest()
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
        }
        try? store.execute(req)
    }
}

// MARK: - Seed Photos
private enum PhotoSeeder {
    static let albumName = "EscrowBench_Album"

    private static func requestPhotosAuthIfNeeded() {
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in sem.signal() }
        sem.wait()
    }

    private static func sourceURL() -> URL {
        guard let p = ProcessInfo.processInfo.environment["PHOTO_SOURCE_PATH"], !p.isEmpty else {
            fatalError("PHOTO_SOURCE_PATH not set")
        }
        var u = URL(fileURLWithPath: p)
        if !FileManager.default.fileExists(atPath: u.path) {
            if let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
                let candidate = pics.appendingPathComponent(p)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    u = candidate
                }
            }
        }
        guard FileManager.default.fileExists(atPath: u.path) else {
            fatalError("PHOTO_SOURCE_PATH does not exist: \(u.path)")
        }
        return u
    }

    private static func ensureAlbum() -> PHAssetCollection? {
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var album: PHAssetCollection?
        existing.enumerateObjects { c, _, stop in
            if c.localizedTitle == albumName { album = c; stop.pointee = true }
        }
        if let album { return album }

        var placeholder: PHObjectPlaceholder?
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges({
            let r = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            placeholder = r.placeholderForCreatedAssetCollection
        }) { _, _ in sem.signal() }
        sem.wait()
        guard let ph = placeholder else { return nil }
        let res = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [ph.localIdentifier], options: nil)
        return res.firstObject
    }

    static func reset(to count: Int) {
        requestPhotosAuthIfNeeded()
        remove()
        if count > 0 { add(count: count) }
    }

    static func remove() {
        guard let album = ensureAlbum() else { return }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        guard assets.count > 0 else { return }
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
        guard count > 0 else { return }
        let src = sourceURL()
        guard let album = ensureAlbum() else { return }
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
                let imgData = try? Data(contentsOf: src)
                if imgData == nil { fatalError("Cannot read PHOTO_SOURCE_PATH: \(src.path)") }
                for _ in 0..<n {
                    let cr = PHAssetCreationRequest.forAsset()
                    cr.addResource(with: .photo, data: imgData!, options: nil)
                    if let ph = cr.placeholderForCreatedAsset { placeholders.append(ph) }
                }
                if placeholders.count != n {
                    // Most likely file access problem or Photos refused; force fail
                    fatalError("Failed to stage all photo creations: staged=\(placeholders.count) of n=\(n)")
                }
                albumReq?.addAssets(NSArray(array: placeholders))
            }) { ok, err in
                if !ok {
                    fatalError("PHPhotoLibrary performChanges failed: \(err?.localizedDescription ?? "unknown error")")
                }
                sem.signal()
            }
            sem.wait()
            created += n
        }
    }
}

struct OverheadBenchRunner {
    private static let dataSize: Int =
        Int(ProcessInfo.processInfo.environment["SIZE"] ?? "100") ?? 100
    private static let csvURL: URL = {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return docs.appendingPathComponent("bench_overhead_\(dataSize).csv")
    }()

    private static var initialized = false
    private static func appendCSV(_ line: String) {
        let header = "approach,query,size,mean_ms,std_ms\n"
        if !initialized {
            try? FileManager.default.removeItem(at: csvURL)
            try? header.data(using: .utf8)?.write(to: csvURL)
            initialized = true
        }
        if let d = (line + "\n").data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: csvURL) {
                _ = try? fh.seekToEnd()
                fh.write(d)
                try? fh.close()
            }
        }
    }

    private static func baselineContact() -> Bool {
        let store = CNContactStore()
        let pred = CNContact.predicateForContacts(matchingName: "uniqueName")
        let keys: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        guard
            let contact = try? store.unifiedContacts(
                matching: pred,
                keysToFetch: keys
            ).first,
            let phone = contact.phoneNumbers.first?.value.stringValue
        else { return false }
        return Utils.isValidUSPhone(phone)
    }

    private static func baselinePhotos() -> Int {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(
            format: "mediaType == %d",
            PHAssetMediaType.image.rawValue
        )
        opts.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        opts.fetchLimit = 100
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        var images: [Any] = []
        fetch.enumerateObjects { asset, idx, stop in
            #if canImport(AppKit)
                if let img = Utils.image(from: asset) { images.append(img) }
            #else
                images.append(asset)
            #endif
        }
        return images.count
    }

    private static let locMgr = CLLocationManager()

    private static func baselineLocation() -> Double? {
        //        let mgr = CLLocationManager()
        //        mgr.requestWhenInUseAuthorization()
        let deadline = Date().addingTimeInterval(5)
        var loc: CLLocation?
        repeat {
            loc = locMgr.location
            if loc == nil {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        } while loc == nil && Date() < deadline
        guard let l = loc else {
            fatalError("baseline did not return a location")
        }
        return Utils.weatherForLocation(l)
    }

    private static func escrowContact() -> Bool {
        return Escrow.shared.run(
            access:
                "SELECT mainPhoneNumber FROM Contacts WHERE givenName = 'uniqueName'"
        ) { rows in
            guard let phone = rows.first?["mainPhoneNumber"] as? String else {
                return false
            }
            return Utils.isValidUSPhone(phone)
        }
    }

    private static func escrowPhotos() -> Int {
        return Escrow.shared.run(
            access:
                "SELECT phasset FROM Photos WHERE mediaType = 1 ORDER BY creationDate DESC LIMIT 100"
        ) { rows in
            var imgs: [Any] = []
            rows.forEach { r in
                guard let asset = r["phasset"] as? PHAsset else { return }
                #if canImport(AppKit)
                    if let img = Utils.image(from: asset) { imgs.append(img) }
                #else
                    imgs.append(asset)
                #endif
            }
            return imgs.count
        }
    }

    private static func escrowLocation() -> Double? {
        let deadline = Date().addingTimeInterval(5)
        var temp: Double?
        repeat {
            temp = Escrow.shared.run(
                access:
                    "SELECT location FROM Location ORDER BY timestamp DESC LIMIT 1"
            ) { rows in
                guard let loc = rows.first?["location"] as? CLLocation else {
                    return nil
                }
                //                print(loc.debugDescription)
                return Utils.weatherForLocation(loc)
            }
            if temp == nil {
                Thread.sleep(forTimeInterval: 0.1)
            }
        } while temp == nil && Date() < deadline
        guard temp != nil else {
            fatalError("escrow return temp = nil")
        }
        return temp
    }

    private static func time<T>(_ fn: () -> T) -> Double {
        var t = NanoTimer()
        t.start()
        _ = fn()
        return t.stopMs()
    }

    private static func benchQuery<T>(
        name: String,
        size: Int,
        escrow: () -> T,
        baseline: () -> T
    ) where T: Equatable {
        // Ensure outputs match once before timing
        let outEscrow = escrow()
        let outBase = baseline()
        assert(outEscrow == outBase, "Outputs mismatch for \(name)")

        // Escrow timings
        var eSamples: [Double] = []
        for _ in 0..<10 {
            eSamples.append(
                time {
                    escrow()
                }
            )
        }
        appendCSV("escrow,\(name),\(size),\(eSamples.mean),\(eSamples.std)")
        print(
            "Escrow \(name) size \(size): \(eSamples.mean) ms ± \(eSamples.std)"
        )

        // Baseline timings
        var bSamples: [Double] = []
        for _ in 0..<10 {
            bSamples.append(
                time {
                    baseline()
                }
            )
        }
        appendCSV("baseline,\(name),\(size),\(bSamples.mean),\(bSamples.std)")
        print(
            "Baseline \(name) size \(size): \(bSamples.mean) ms ± \(bSamples.std)"
        )
    }

    private static func benchSize(_ size: Int) {
        print("\n=== Overhead Benchmark size = \(size) ===")
        DispatchQueue.main.sync {
            _ = Escrow.shared
        }
        locMgr.requestWhenInUseAuthorization()

        ContactSeeder.reset(to: size)
        PhotoSeeder.reset(to: size)
        benchQuery(
            name: "contact_valid",
            size: size,
            escrow: { escrowContact() },
            baseline: { baselineContact() }
        )
        benchQuery(
            name: "photo_transform",
            size: size,
            escrow: { escrowPhotos() },
            baseline: { baselinePhotos() }
        )
        benchQuery(
            name: "location_weather",
            size: 0,
            escrow: { escrowLocation() },
            baseline: { baselineLocation() }
        )
        ContactSeeder.reset(to: 0)
        PhotoSeeder.reset(to: 0)
    }

    static func kickOff() {
        DispatchQueue.global(qos: .userInitiated).async {
            benchSize(dataSize)
            print("Overhead benchmark finished – see CSV at \(csvURL.path())")
        }
    }
}
