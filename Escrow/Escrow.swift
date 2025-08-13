//
//  Escrow.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Contacts
import Foundation
import Photos
import SQLite3

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
        case .text(let x):
            return x
        case .int(let x):
            return x
        case .float(let x):
            return x
        case .bool(let x):
            return x
        case .date(let x):
            return x
        case .blob(let x):
            return x
        case .phasset(let x):
            return x
        case .location(let x):
            return x
        case .null:
            return nil
        case .custom(let x):
            return x
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
    public func index(after i: Int) -> Int {
        pairs.index(after: i)
    }

    public subscript(key: String) -> Any? {
        pairs.first { $0.key == key }?.value.any
    }

    public func cell(_ key: String) -> CellValue? {
        pairs.first { $0.key == key }?.value
    }

    public init(dictionaryLiteral elements: (String, CellValue)...) {
        self.pairs = elements
    }

    init(_ pairs: [(String, CellValue)]) {
        self.pairs = pairs
    }
}

extension Row {
    func get<T>(_ key: String) -> T? {
        return self[key] as? T
    }
}

public final class Escrow {
    // Records milliseconds spent preloading each table
    public static var preloadMetrics: [String: Double] = [:]
    public static let shared = Escrow()
    private var db: OpaquePointer?

    private init() {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

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

        /* Ensure LocationBuffer is initialised on the main thread */
        _ = LocationBuffer.shared

        guard register_contacts_module(db) == SQLITE_OK,
            register_photos_module(db) == SQLITE_OK,
            register_location_module(db) == SQLITE_OK
        else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

        guard
            sqlite3_exec(
                db,
                "CREATE VIRTUAL TABLE Contacts USING contacts_module; CREATE VIRTUAL TABLE Photos USING photos_module; CREATE VIRTUAL TABLE Location USING location_module;",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        else {
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
            var row: [(String, CellValue)] = []
            for i in 0..<sqlite3_column_count(stmt) {
                let cname = String(cString: sqlite3_column_name(stmt, i))
                let ctype = sqlite3_column_type(stmt, i)
                let value: CellValue

                switch ctype {
                case SQLITE_INTEGER:
                    value = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT
                where (cname == "creationDate" || cname == "timestamp"):
                    value = .date(
                        Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                stmt,
                                i
                            )
                        )
                    )
                case SQLITE_FLOAT:
                    value = .float(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    value = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB where cname == "phasset":
                    let raw = sqlite3_column_blob(stmt, i)
                    let opaque = raw!.assumingMemoryBound(
                        to: UnsafeRawPointer?.self
                    ).pointee
                    let asset = Unmanaged<PHAsset>.fromOpaque(opaque!)
                        .takeRetainedValue()
                    value = .phasset(asset)
                case SQLITE_BLOB where cname == "location":
                    let raw = sqlite3_column_blob(stmt, i)
                    let opaque = raw!.assumingMemoryBound(
                        to: UnsafeRawPointer?.self
                    ).pointee
                    let loc = Unmanaged<CLLocation>.fromOpaque(opaque!)
                        .takeRetainedValue()
                    value = .location(loc)
                //                case SQLITE_FLOAT where cname == "timestamp":
                //                    value = .float(sqlite3_column_double(stmt, i))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(stmt, i)
                    let len = sqlite3_column_bytes(stmt, i)
                    value = .blob(Data(bytes: bytes!, count: Int(len)))
                default: value = .null
                }
                row.append((cname, value))
            }
            rows.append(Row(row))
        }
        guard sqlite3_finalize(stmt) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }
        return compute(rows)
    }

    public func runWithTiming<T>(access sql: String, compute: ([Row]) -> T) -> (
        T, Double, Double
    ) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

        let accessTimer = DispatchTime.now().uptimeNanoseconds
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [(String, CellValue)] = []
            for i in 0..<sqlite3_column_count(stmt) {
                let cname = String(cString: sqlite3_column_name(stmt, i))
                let ctype = sqlite3_column_type(stmt, i)
                let value: CellValue

                switch ctype {
                case SQLITE_INTEGER:
                    value = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT
                where (cname == "creationDate" || cname == "timestamp"):
                    value = .date(
                        Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                stmt,
                                i
                            )
                        )
                    )
                case SQLITE_FLOAT:
                    value = .float(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    value = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB where cname == "phasset":
                    let raw = sqlite3_column_blob(stmt, i)
                    let opaque = raw!.assumingMemoryBound(
                        to: UnsafeRawPointer?.self
                    ).pointee
                    let asset = Unmanaged<PHAsset>.fromOpaque(opaque!)
                        .takeRetainedValue()
                    value = .phasset(asset)
                case SQLITE_BLOB where cname == "location":
                    let raw = sqlite3_column_blob(stmt, i)
                    let opaque = raw!.assumingMemoryBound(
                        to: UnsafeRawPointer?.self
                    ).pointee
                    let loc = Unmanaged<CLLocation>.fromOpaque(opaque!)
                        .takeRetainedValue()
                    value = .location(loc)
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(stmt, i)
                    let len = sqlite3_column_bytes(stmt, i)
                    value = .blob(Data(bytes: bytes!, count: Int(len)))
                default: value = .null
                }
                row.append((cname, value))
            }
            rows.append(Row(row))
        }
        guard sqlite3_finalize(stmt) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }
        let accessNs = DispatchTime.now().uptimeNanoseconds - accessTimer

        let computeStart = DispatchTime.now().uptimeNanoseconds
        let result = compute(rows)
        let computeNs = DispatchTime.now().uptimeNanoseconds - computeStart

        let accessMs = Double(accessNs) / 1_000_000.0
        let computeMs = Double(computeNs) / 1_000_000.0
        return (result, accessMs, computeMs)
    }
}
