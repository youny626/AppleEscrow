//
//  ContactsBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Foundation
import Contacts

// Bit positions copied from colUsed → colMask (keep in sync with C)
private struct ColMask {
    static let firstName:    UInt = 1 << 0
    static let lastName:     UInt = 1 << 1
    static let phoneNumbers: UInt = 1 << 2
}

// Snapshot returned to C as an opaque pointer
private final class ContactsHandle {
    let given:  [String]
    let family: [String]
    let phones: [String]
    let mask:   UInt
    init(given: [String], family: [String], phones: [String], mask: UInt) {
        self.given  = given
        self.family = family
        self.phones = phones
        self.mask   = mask
    }
}

typealias ContactsHandlePtr = OpaquePointer

// Duplicate Swift String → malloc'ed C string so C side can free with free()
private func dupCString(_ str: String) -> UnsafePointer<CChar>? {
    guard let dup = strdup(str) else { return nil }
    return UnsafePointer<CChar>(dup)
}

// MARK: contacts_vtab_prepare ------------------------------------------------
@_cdecl("contacts_vtab_prepare")
func contacts_vtab_prepare(_ firstPrefixC: UnsafePointer<CChar>?,
                           _ lastPrefixC:  UnsafePointer<CChar>?,
                           _ colMask:      UInt,
                           _ outHandle:    UnsafeMutablePointer<ContactsHandlePtr?>!,
                           _ outRowCount:  UnsafeMutablePointer<Int32>!) -> Int32 {
    let firstPrefix = firstPrefixC.flatMap { String(cString: $0) }
    let lastPrefix  = lastPrefixC.flatMap  { String(cString: $0) }

    // Build keysToFetch based on projection
    var keys: [CNKeyDescriptor] = []
    if colMask & ColMask.firstName    != 0 { keys.append(CNContactGivenNameKey    as CNKeyDescriptor) }
    if colMask & ColMask.lastName     != 0 { keys.append(CNContactFamilyNameKey   as CNKeyDescriptor) }
    if colMask & ColMask.phoneNumbers != 0 { keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor) }
    if keys.isEmpty { keys = [CNContactIdentifierKey as CNKeyDescriptor] }

    // Fetch contacts (simple linear scan; good enough for a demo)
    var g:[String]=[], f:[String]=[], p:[String]=[]
    let store = CNContactStore()
    let request = CNContactFetchRequest(keysToFetch: keys)
    try? store.enumerateContacts(with: request) { contact, _ in
        if let pref = firstPrefix, !pref.isEmpty, !contact.givenName.hasPrefix(pref) { return }
        if let pref = lastPrefix,  !pref.isEmpty, !contact.familyName.hasPrefix(pref){ return }
        g.append(contact.givenName)
        f.append(contact.familyName)
        let joined = contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
        p.append(joined)
    }

    let snap = ContactsHandle(given: g, family: f, phones: p, mask: colMask)
    let unmanaged = Unmanaged.passRetained(snap)
    outHandle.pointee  = ContactsHandlePtr(unmanaged.toOpaque())
    outRowCount.pointee = Int32(g.count)
    return 0
}

// MARK: contacts_vtab_row ----------------------------------------------------
@_cdecl("contacts_vtab_row")
func contacts_vtab_row(_ handlePtr: ContactsHandlePtr?,
                       _ rowIndex:  Int32,
                       _ outFirst:  UnsafeMutablePointer<UnsafePointer<CChar>?>!,
                       _ outLast:   UnsafeMutablePointer<UnsafePointer<CChar>?>!,
                       _ outPhone:  UnsafeMutablePointer<UnsafePointer<CChar>?>!) {
    guard let handlePtr = handlePtr else { return }
    let snap = Unmanaged<ContactsHandle>.fromOpaque(UnsafeRawPointer(handlePtr)).takeUnretainedValue()
    let i = Int(rowIndex)
    if i >= snap.given.count { return }

    // firstName
    if snap.mask & ColMask.firstName != 0 {
        outFirst.pointee = dupCString(snap.given[i])
    } else {
        outFirst.pointee = dupCString("")
    }
    // lastName
    if snap.mask & ColMask.lastName != 0 {
        outLast.pointee = dupCString(snap.family[i])
    } else {
        outLast.pointee = dupCString("")
    }
    // phones
    if snap.mask & ColMask.phoneNumbers != 0 {
        outPhone.pointee = dupCString(snap.phones[i])
    } else {
        outPhone.pointee = dupCString("")
    }
}

// MARK: contacts_vtab_release ------------------------------------------------
@_cdecl("contacts_vtab_release")
func contacts_vtab_release(_ handlePtr: ContactsHandlePtr?) {
    if let handlePtr = handlePtr {
        Unmanaged<ContactsHandle>.fromOpaque(UnsafeRawPointer(handlePtr)).release()
    }
}
