//
//  ContactsBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Foundation
import Contacts

// Swift-side row cache
var cachedContacts: [(String, String, String)] = []

// Bridging function called from contacts_vtab.c
@_cdecl("contacts_vtab_query")
func contacts_vtab_query(_ filterPrefix: UnsafePointer<CChar>?,
                         _ rowIndex: Int32,
                         _ outFirst: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
                         _ outLast:  UnsafeMutablePointer<UnsafePointer<CChar>?>!,
                         _ outPhone: UnsafeMutablePointer<UnsafePointer<CChar>?>!) -> Int32 {

    // Prime cache on first call
    if cachedContacts.isEmpty {
        let store   = CNContactStore()
        let keys    = [CNContactGivenNameKey,
                       CNContactFamilyNameKey,
                       CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { c, _ in
            let phones = c.phoneNumbers
                           .map { $0.value.stringValue }
                           .joined(separator: ", ")
            cachedContacts.append((c.givenName, c.familyName, phones))
        }
    }

    // Bounds check
    guard rowIndex < cachedContacts.count else {
        outFirst.pointee = nil; outLast.pointee = nil; outPhone.pointee = nil
        return 0
    }

    // Return row values
    let (fn, ln, ph) = cachedContacts[Int(rowIndex)]
    outFirst.pointee = UnsafePointer(strdup(fn))
    outLast .pointee = UnsafePointer(strdup(ln))
    outPhone.pointee = UnsafePointer(strdup(ph))
    return 0
}
