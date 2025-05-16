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

// MARK: contacts_vtab_prepare ------------------------------------------------
@_cdecl("contacts_vtab_prepare")
func contacts_vtab_prepare(
    _ firstC: UnsafePointer<CChar>?,
    _ lastC: UnsafePointer<CChar>?,
    _ colMask: UInt,
    _ outHandle: UnsafeMutablePointer<ContactsHandlePtr?>!,
    _ outCount: UnsafeMutablePointer<Int32>!
) -> Int32 {
    // ---------- Decode raw strings & classify (none / exact / prefix) ------
    enum Match {
        case none
        case exact(String)
        case prefix(String)
    }
    func classify(_ ptr: UnsafePointer<CChar>?) -> Match {
        guard let ptr = ptr else { return .none }
        var s = String(cString: ptr)
        if s.isEmpty { return .none }
        if s.last == "%" {
            s.removeLast()
            return .prefix(s)
        }
        return .exact(s)
    }
    let firstM = classify(firstC)
    let lastM = classify(lastC)

    // ---------- Choose Contacts predicate (best effort) --------------------
    func predicate(for first: Match, _ last: Match) -> NSPredicate? {
        switch (first, last) {
        case (.none, .none): return nil
        case (.exact(let f), .none):
            return CNContact.predicateForContacts(matchingName: f)
        case (.prefix(let fP), .none):
            return CNContact.predicateForContacts(matchingName: fP)
        case (.none, .exact(let l)):
            return CNContact.predicateForContacts(matchingName: l)
        case (.none, .prefix(let lP)):
            return CNContact.predicateForContacts(matchingName: lP)
        case (.exact(let f), .exact(let l)):
            return CNContact.predicateForContacts(matchingName: "\(f) \(l)")
        case (.exact(let f), .prefix(let lp)):
            return CNContact.predicateForContacts(matchingName: "\(f) \(lp)")
        case (.prefix, .exact(let l)):
            return CNContact.predicateForContacts(matchingName: l)  // safest
        case (.prefix(let fp), .prefix(let lp)):
            return CNContact.predicateForContacts(matchingName: "\(fp) \(lp)")
        }
    }

    let pred = predicate(for: firstM, lastM)

    // ---------- Build keys for projection ----------------------------------
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

    // ---------- Fetch contacts ---------------------------------------------
    let store = CNContactStore()
    var g: [String] = []
    var f: [String] = []
    var p: [String] = []
    func append(_ c: CNContact) {
        g.append(c.givenName)
        f.append(c.familyName)
        p.append(
            c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
        )
    }
    do {
        if let pr = pred {
            let cs = try store.unifiedContacts(matching: pr, keysToFetch: keys)
            cs.forEach(append)
        } else {
            let req = CNContactFetchRequest(keysToFetch: keys)
            try store.enumerateContacts(with: req) { c, _ in append(c) }
        }
    } catch {
        /* on failure return 0 rows */
    }

    // ---------- Ship snapshot back to C ------------------------------------
    let snap = ContactsHandle(given: g, family: f, phones: p, mask: colMask)
    outHandle.pointee = ContactsHandlePtr(
        Unmanaged.passRetained(snap).toOpaque()
    )
    outCount.pointee = Int32(g.count)
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
