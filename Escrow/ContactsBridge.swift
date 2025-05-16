//
//  ContactsBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Contacts
import Foundation

// Bit positions copied from colUsed → colMask (keep in sync with C)
private struct ColMask {
    static let firstName: UInt = 1 << 0
    static let lastName: UInt = 1 << 1
    static let phoneNumbers: UInt = 1 << 2
}

// Snapshot returned to C as an opaque pointer
private final class ContactsHandle {
    let given: [String]
    let family: [String]
    let phones: [String]
    let mask: UInt
    init(given: [String], family: [String], phones: [String], mask: UInt) {
        self.given = given
        self.family = family
        self.phones = phones
        self.mask = mask
    }
}

typealias ContactsHandlePtr = OpaquePointer

// Duplicate Swift String → malloc'ed C string so C side can free with free()
private func dupCString(_ str: String) -> UnsafePointer<CChar>? {
    guard let dup = strdup(str) else { return nil }
    return UnsafePointer<CChar>(dup)
}

// MARK: contacts_vtab_prepare
@_cdecl("contacts_vtab_prepare")
func contacts_vtab_prepare(
    _ firstC: UnsafePointer<CChar>?,
    _ lastC: UnsafePointer<CChar>?,
    _ colMask: UInt,
    _ outHandle: UnsafeMutablePointer<ContactsHandlePtr?>!,
    _ outCount: UnsafeMutablePointer<Int32>!
) -> Int32 {
    // 1. Decode raw strings and strip trailing “%”
    func clean(_ ptr: UnsafePointer<CChar>?) -> String? {
        guard var s = ptr.flatMap({ String(cString: $0) }), !s.isEmpty else {
            return nil
        }
        if s.last == "%" { s.removeLast() }
        return s.isEmpty ? nil : s  // might become empty after %
    }
    let firstPart = clean(firstC)
    let lastPart = clean(lastC)

    // 2. Build Contacts predicate (if any)
    var predicate: NSPredicate? = nil
    if let f = firstPart, let l = lastPart {
        predicate = CNContact.predicateForContacts(matchingName: "\(f) \(l)")
    } else if let f = firstPart {
        predicate = CNContact.predicateForContacts(matchingName: f)
    } else if let l = lastPart {
        predicate = CNContact.predicateForContacts(matchingName: l)
    }  // else: no usable predicate → enumerate all

    // 3. Keys to fetch for projection push-down
    var keys: [CNKeyDescriptor] = []
    if colMask & ColMask.firstName != 0 {
        keys.append(CNContactGivenNameKey as CNKeyDescriptor)
    }
    if colMask & ColMask.lastName != 0 {
        keys.append(CNContactFamilyNameKey as CNKeyDescriptor)
    }
    if colMask & ColMask.phoneNumbers != 0 {
        keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor)
    }
    if keys.isEmpty { keys = [CNContactIdentifierKey as CNKeyDescriptor] }

    // 4. Fetch contacts
    let store = CNContactStore()
    var given: [String] = []
    var family: [String] = []
    var phones: [String] = []

    func append(_ c: CNContact) {
        given.append(c.givenName)
        family.append(c.familyName)
        phones.append(
            c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
        )
    }

    do {
        if let pred = predicate {
            let hits = try store.unifiedContacts(
                matching: pred,
                keysToFetch: keys
            )
            hits.forEach(append)
        } else {
            let req = CNContactFetchRequest(keysToFetch: keys)
            try store.enumerateContacts(with: req) { c, _ in append(c) }
        }
    } catch {
        // On error we simply return zero rows
        fatalError(error.localizedDescription)
    }

    // 5. Return snapshot to C
    let snap = ContactsHandle(
        given: given,
        family: family,
        phones: phones,
        mask: colMask
    )
    outHandle.pointee = ContactsHandlePtr(
        Unmanaged.passRetained(snap).toOpaque()
    )
    outCount.pointee = Int32(given.count)
    return 0
}

// MARK: contacts_vtab_row ----------------------------------------------------
@_cdecl("contacts_vtab_row")
func contacts_vtab_row(
    _ handlePtr: ContactsHandlePtr?,
    _ rowIndex: Int32,
    _ outFirst: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ outLast: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ outPhone: UnsafeMutablePointer<UnsafePointer<CChar>?>!
) {
    guard let handlePtr = handlePtr else { return }
    let snap = Unmanaged<ContactsHandle>.fromOpaque(UnsafeRawPointer(handlePtr))
        .takeUnretainedValue()
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
        Unmanaged<ContactsHandle>.fromOpaque(UnsafeRawPointer(handlePtr))
            .release()
    }
}
