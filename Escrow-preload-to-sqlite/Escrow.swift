import Contacts
import CoreLocation
import Foundation
import Photos
import SQLite3

// Helper constant: sqlite3_destructor_type(-1) so SQLite copies strings
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

public enum CellValue {
    case text(String)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case date(Date)
    case blob(Data)
    case phasset(PHAsset)
    case location(CLLocation)
    case null
    case custom(Any)
}

extension CellValue {
    var any: Any? {
        switch self {
        case .text(let x): return x
        case .int(let x): return x
        case .float(let x): return x
        case .bool(let x): return x
        case .date(let x): return x
        case .blob(let x): return x
        case .phasset(let x): return x
        case .location(let x): return x
        case .null: return nil
        case .custom(let x): return x
        }
    }
}

public struct Row: RandomAccessCollection, ExpressibleByDictionaryLiteral {
    private var pairs: [(key: String, value: CellValue)]

    public typealias Index = Int
    public var startIndex: Int { pairs.startIndex }
    public var endIndex: Int { pairs.endIndex }

    public subscript(position: Int) -> (key: String, value: CellValue) {
        pairs[position]
    }
    public func index(after i: Int) -> Int { pairs.index(after: i) }

    public subscript(key: String) -> Any? {
        pairs.first { $0.key == key }?.value.any
    }

    public func cell(_ key: String) -> CellValue? {
        pairs.first { $0.key == key }?.value
    }

    public init(dictionaryLiteral elements: (String, CellValue)...) {
        self.pairs = elements
    }

    init(_ pairs: [(String, CellValue)]) { self.pairs = pairs }
}

// Simple timer for ms precision
private struct NanoTimer {
    private var t0: UInt64 = 0
    mutating func start() { t0 = DispatchTime.now().uptimeNanoseconds }
    func stopMs() -> Double {
        let diff = DispatchTime.now().uptimeNanoseconds - t0
        return Double(diff) / 1_000_000.0
    }
}

extension Row {
    func get<T>(_ key: String) -> T? { self[key] as? T }
}

public final class Escrow {
    // Records milliseconds spent preloading each table
    public static var preloadMetrics: [String: Double] = [:]
    public static let shared = Escrow()
    private var db: OpaquePointer?

    // Reused prepared stmt for Location inserts
    private var locInsertStmt: OpaquePointer?

    private init() {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

        // Request permissions so the frameworks can be accessed
        let contactStore = CNContactStore()
        contactStore.requestAccess(for: .contacts) { granted, error in
            if granted {
                print("Contacts permission granted")
            } else {
                print("Contacts permission denied: \(error.debugDescription)")
            }
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            if status == .authorized {
                print("Photos permission granted")
            } else {
                print("Photos permission denied")
            }
        }

        _ = LocationBuffer.shared  // ensure manager set-up

        createSchema()

        var timer = NanoTimer()

        timer.start()
        preloadContacts()
        Escrow.preloadMetrics["contacts_ms"] = timer.stopMs()

        timer.start()
        preloadPhotos()
        Escrow.preloadMetrics["photos_ms"] = timer.stopMs()

        timer.start()
        if let firstLocation = CLLocationManager().location {
            insertLocation(firstLocation)
        }
        Escrow.preloadMetrics["location_ms"] = timer.stopMs()
    }

    private func createSchema() {
        let ddl = [
            // Contacts schema
            "CREATE TABLE Contacts (identifier TEXT PRIMARY KEY, givenName TEXT, familyName TEXT, mainPhoneNumber TEXT);",
            // Photos schema – mimics vtab columns; phasset is TEXT (identifier)
            "CREATE TABLE Photos (identifier TEXT PRIMARY KEY, mediaType INT, creationDate REAL, collectionIdentifier TEXT, collectionName TEXT, phasset TEXT);",
            // Location schema – simple scalar columns
            "CREATE TABLE Location (timestamp REAL, latitude REAL, longitude REAL, hAccuracy REAL, location TEXT);",
        ].joined()

        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

        // prepare Location insert statement once
        let ins =
            "INSERT INTO Location (timestamp, latitude, longitude, hAccuracy, location) VALUES (?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, ins, -1, &locInsertStmt, nil) == SQLITE_OK
        else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func preloadContacts() {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let insertSQL =
            "INSERT OR IGNORE INTO Contacts (identifier, givenName, familyName, mainPhoneNumber) VALUES (?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK
        else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        do {
            try store.enumerateContacts(
                with: CNContactFetchRequest(keysToFetch: keys)
            ) { contact, _ in
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(
                    stmt,
                    1,
                    (contact.identifier as NSString).utf8String,
                    -1,
                    SQLITE_TRANSIENT
                )
                sqlite3_bind_text(
                    stmt,
                    2,
                    (contact.givenName as NSString).utf8String,
                    -1,
                    SQLITE_TRANSIENT
                )
                sqlite3_bind_text(
                    stmt,
                    3,
                    (contact.familyName as NSString).utf8String,
                    -1,
                    SQLITE_TRANSIENT
                )
                let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
                sqlite3_bind_text(
                    stmt,
                    4,
                    (phone as NSString).utf8String,
                    -1,
                    SQLITE_TRANSIENT
                )
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    fatalError(
                        "[Escrow preload] contact insert failed: \(String(cString: sqlite3_errmsg(db)))"
                    )
                }
            }
        } catch {
            print(error)
        }
    }

    private func preloadPhotos() {
        let opts = PHFetchOptions()
        let fetch: PHFetchResult<PHAsset> = PHAsset.fetchAssets(with: opts)

        let insertSQL =
            "INSERT OR IGNORE INTO Photos (identifier, mediaType, creationDate, collectionIdentifier, collectionName, phasset) VALUES (?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK
        else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        fetch.enumerateObjects { asset, _, _ in
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(
                stmt,
                1,
                (asset.localIdentifier as NSString).utf8String,
                -1,
                SQLITE_TRANSIENT
            )
            sqlite3_bind_int(stmt, 2, Int32(asset.mediaType.rawValue))
            sqlite3_bind_double(
                stmt,
                3,
                asset.creationDate?.timeIntervalSince1970 ?? 0
            )
            // Collection info (first album containing the asset, if any)
            let colls = PHAssetCollection.fetchAssetCollectionsContaining(
                asset,
                with: .album,
                options: nil
            )
            let collId = colls.firstObject?.localIdentifier ?? ""
            let collName = colls.firstObject?.localizedTitle ?? ""
            sqlite3_bind_text(
                stmt,
                4,
                (collId as NSString).utf8String,
                -1,
                SQLITE_TRANSIENT
            )
            sqlite3_bind_text(
                stmt,
                5,
                (collName as NSString).utf8String,
                -1,
                SQLITE_TRANSIENT
            )
            sqlite3_bind_text(
                stmt,
                6,
                (asset.localIdentifier as NSString).utf8String,
                -1,
                SQLITE_TRANSIENT
            )  // store id again for phasset column
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                fatalError(
                    "[Escrow preload] photo insert failed: \(String(cString: sqlite3_errmsg(self.db)))"
                )
            }
        }
    }

    // Direct insert helper – called from LocationBuffer and at app start
    func insertLocation(_ loc: CLLocation) {
        guard let stmt = locInsertStmt else { return }

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_double(stmt, 1, loc.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, loc.coordinate.latitude)
        sqlite3_bind_double(stmt, 3, loc.coordinate.longitude)
        sqlite3_bind_double(stmt, 4, loc.horizontalAccuracy)
        sqlite3_bind_text(
            stmt,
            5,
            ("" as NSString).utf8String,
            -1,
            SQLITE_TRANSIENT
        )
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func run<T>(access sql: String, compute: ([Row]) -> T) -> T {

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var scratch: [String: CellValue] = [:]
            // read raw columns first
            for i in 0..<sqlite3_column_count(stmt) {
                let cname = String(cString: sqlite3_column_name(stmt, i))
                let ctype = sqlite3_column_type(stmt, i)
                let val: CellValue
                switch ctype {
                case SQLITE_INTEGER:
                    val = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT
                where (cname == "creationDate" || cname == "timestamp"):
                    val = .date(
                        Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                stmt,
                                i
                            )
                        )
                    )
                case SQLITE_FLOAT:
                    val = .float(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    val = .text(String(cString: sqlite3_column_text(stmt, i)))
                default:
                    val = .null
                }
                scratch[cname] = val
            }

            // post-process synthetic columns
            if let idVal = scratch["phasset"], case let .text(id) = idVal {
                let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [id],
                    options: nil
                ).firstObject
                if let a = asset {
                    scratch["phasset"] = .phasset(a)
                } else {
                    scratch["phasset"] = .null
                }
            }
            if scratch["location"] != nil {  // location column was selected
                if let lat = scratch["latitude"],
                    let lon = scratch["longitude"],
                    let date = scratch["timestamp"],
                    case let .float(la) = lat, case let .float(lo) = lon,
                    case let .date(ts) = date
                {
                    let loc = CLLocation(
                        coordinate: CLLocationCoordinate2D(
                            latitude: la,
                            longitude: lo
                        ),
                        altitude: 0,
                        horizontalAccuracy: (scratch["hAccuracy"]?.any
                            as? Double) ?? 0,
                        verticalAccuracy: -1,
                        timestamp: ts
                    )
                    scratch["location"] = .location(loc)
                } else {
                    scratch["location"] = .null
                }
            }

            rows.append(Row(scratch.map { ($0.key, $0.value) }))
        }

        guard sqlite3_finalize(stmt) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

        return compute(rows)
    }
}
