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
            if let contact = try? store.unifiedContact(
                withIdentifier: id,
                keysToFetch: []
            ) {
                let mut = contact.mutableCopy() as! CNMutableContact
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
            let phone = CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: "555-\(1000+i)")
            )
            c.phoneNumbers = [phone]
            req.add(c, toContainerWithIdentifier: nil)
        }
        try? store.execute(req)
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
    }

    static func kickOff() {
        // run asynchronously so UI can finish launching
        DispatchQueue.global(qos: .userInitiated).async {
            benchSize(dataSize)
            print("Bench finished – see CSV file in \(url.path())")
        }
    }
}
