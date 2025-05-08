//
//  Escrow.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Foundation
import SQLite3
import Contacts

public enum SQLValue {
    case text(String)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case date(Date)
    case blob(Data)
    case null
    case custom(Any)
}
public typealias Row = [String: SQLValue]

public final class Escrow {
    public static let shared = Escrow()
    private var db: OpaquePointer?

    private init() {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            fatalError("Could not open SQLite")
        }
        
        let contactStore = CNContactStore()
        contactStore.requestAccess(for: .contacts) { granted, error in
            if granted {
                print("Contacts permission granted")
            } else {
                print("Contacts permission denied: \(error.debugDescription)")
            }
        }
        
        register_contacts_module(db)
        
        sqlite3_exec(db,
          "CREATE VIRTUAL TABLE Contacts USING contacts_module;",
          nil,nil,nil)
    }

    public func run<T>(access sql: String, compute: ([Row]) -> T) -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
        else { fatalError("bad SQL") }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: Row = [:]
            for i in 0 ..< sqlite3_column_count(stmt) {
                let colName = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[colName] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row[colName] = .float(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    row[colName] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_NULL:
                    row[colName] = .null
                default:
                    row[colName] = .null
                }
            }
            rows.append(row)
        }
        sqlite3_finalize(stmt)
        return compute(rows)
    }
}
