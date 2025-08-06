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
        let urlStr =
            "https://api.openweathermap.org/data/2.5/weather?lat=\(loc.coordinate.latitude)&lon=\(loc.coordinate.longitude)&appid=\(apiKey)&units=metric"
        guard let url = URL(string: urlStr) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var temp: Double?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { sem.signal() }
            guard let data = data else { return }
            if let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
                let main = json["main"] as? [String: Any],
                let t = main["temp"] as? Double
            {
                temp = t
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
            let line = String(format: "%04d", i)
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

    private static func baselineLocation() -> Double? {
        let mgr = CLLocationManager()
        mgr.requestWhenInUseAuthorization()
        guard let loc = mgr.location else { return nil }
        return Utils.weatherForLocation(loc)
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
        return Escrow.shared.run(
            access:
                "SELECT location FROM Location ORDER BY timestamp DESC LIMIT 1"
        ) { rows in
            guard let loc = rows.first?["location"] as? CLLocation else {
                return nil
            }
            return Utils.weatherForLocation(loc)
        }
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
        for _ in 0..<10 { eSamples.append(time { _ = escrow() }) }
        appendCSV("escrow,\(name),\(size),\(eSamples.mean),\(eSamples.std)")
        print(
            "Escrow \(name) size \(size): \(eSamples.mean) ms ± \(eSamples.std)"
        )

        // Baseline timings
        var bSamples: [Double] = []
        for _ in 0..<10 { bSamples.append(time { _ = baseline() }) }
        appendCSV("baseline,\(name),\(size),\(bSamples.mean),\(bSamples.std)")
        print(
            "Baseline \(name) size \(size): \(bSamples.mean) ms ± \(bSamples.std)"
        )
    }

    private static func benchSize(_ size: Int) {
        print("\n=== Overhead Benchmark size = \(size) ===")
        ContactSeeder.reset(to: size)
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
    }

    static func kickOff() {
        DispatchQueue.global(qos: .userInitiated).async {
            benchSize(dataSize)
            print("Overhead benchmark finished – see CSV at \(csvURL.path())")
        }
    }
}
