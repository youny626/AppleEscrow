//
//  Escrow.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Contacts
import Foundation
import SQLite3

public enum CellValue {
    case text(String)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case date(Date)
    case blob(Data)
    case null
    case custom(Any)
}

// Row keeps the column order that appeared in the SELECT list
public struct Row: RandomAccessCollection, ExpressibleByDictionaryLiteral {
    private var pairs: [(key: String, value: CellValue)]

    // MARK: Collection conformance (for-in, subscript by index)
    public typealias Index = Int
    public var startIndex: Int { pairs.startIndex }
    public var endIndex: Int { pairs.endIndex }
    public subscript(position: Int) -> (key: String, value: CellValue) {
        pairs[position]
    }
    public func index(after i: Int) -> Int { pairs.index(after: i) }

    // MARK: Keyed lookup
    public subscript(key: String) -> CellValue? {
        pairs.first(where: { $0.key == key })?.value
    }

    // MARK: Literal
    public init(dictionaryLiteral elements: (String, CellValue)...) {
        self.pairs = elements
    }

    // Internal init used by Escrow.run
    init(_ pairs: [(String, CellValue)]) { self.pairs = pairs }
}

public final class Escrow {
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

        guard register_contacts_module(db) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }

        guard
            sqlite3_exec(
                db,
                "CREATE VIRTUAL TABLE Contacts USING contacts_module;",
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
            var ordered: [(String, CellValue)] = []
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let value: CellValue
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    value = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    value = .float(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    value = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_NULL:
                    value = .null
                default:
                    value = .null
                }
                ordered.append((name, value))
            }
            rows.append(Row(ordered))
        }
        guard sqlite3_finalize(stmt) == SQLITE_OK else {
            fatalError(String(cString: sqlite3_errmsg(db)))
        }
        return compute(rows)
    }
}
