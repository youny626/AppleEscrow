//
//  ContactsBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Foundation
import Contacts

/// Swift callback invoked by contacts_vtab.c
///
/// - Parameters:
///   * filterPrefix  : optional LIKE-prefix (unused for now)
///   * rowIndex      : zero-based row number requested by SQLite
///   * outFirst, outLast, outPhone : C strings you must allocate (`strdup`)
///
/// - Returns: 0  (SQLite ignores the numeric value)
@_cdecl("contacts_vtab_query")
func contacts_vtab_query(_ filterPrefix: UnsafePointer<CChar>?,
                         _ rowIndex:    Int32,
                         _ outFirst:    UnsafeMutablePointer<UnsafePointer<CChar>?>!,
                         _ outLast:     UnsafeMutablePointer<UnsafePointer<CChar>?>!,
                         _ outPhone:    UnsafeMutablePointer<UnsafePointer<CChar>?>!) -> Int32
{
    // 1. Pull a fresh snapshot from CNContactStore
    let store   = CNContactStore()
    let keys    = [CNContactGivenNameKey,
                   CNContactFamilyNameKey,
                   CNContactPhoneNumbersKey] as [CNKeyDescriptor]
    let request = CNContactFetchRequest(keysToFetch: keys)

    var targetFirst = "", targetLast = "", targetPhone = ""
    var current = 0

    try? store.enumerateContacts(with: request) { contact, stop in
        if current == rowIndex {
            targetFirst = contact.givenName
            targetLast  = contact.familyName
            targetPhone = contact.phoneNumbers
                           .map { $0.value.stringValue }
                           .joined(separator: ", ")
            stop.pointee = true          // we found our row, abort early
        }
        current += 1
    }

    // 2. Populate outputs (empty strings if index ≥ count)
    outFirst.pointee = UnsafePointer(strdup(targetFirst))
    outLast .pointee = UnsafePointer(strdup(targetLast))
    outPhone.pointee = UnsafePointer(strdup(targetPhone))

    return 0
}
