//
//  ContactsBridge.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Contacts
import Foundation

// Bit positions copied from colUsed → colMask (keep in sync with C)
private struct ContactsColMask {
    static let identifier: UInt = 1 << 0
    static let givenName: UInt = 1 << 1
    static let familyName: UInt = 1 << 2
    static let mainPhone: UInt = 1 << 3
}

// Snapshot returned to C as an opaque pointer
private final class ContactsHandle {
    let ids, givenNames, familyNames, phones: [String]
    let mask: UInt
    init(
        ids: [String],
        givenNames: [String],
        familyNames: [String],
        phones: [String],
        mask: UInt
    ) {
        self.ids = ids
        self.givenNames = givenNames
        self.familyNames = familyNames
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
    _ idC: UnsafePointer<CChar>?,
    _ givenC: UnsafePointer<CChar>?,
    _ familyC: UnsafePointer<CChar>?,
    _ phoneC: UnsafePointer<CChar>?,
    _ colMask: UInt,
    _ outHandle: UnsafeMutablePointer<ContactsHandlePtr?>!,
    _ outCount: UnsafeMutablePointer<Int32>!
) -> Int32 {
    // 1. Decode raw strings and strip trailing “%”
    func clean(_ ptr: UnsafePointer<CChar>?, _ stripLast: Bool = false)
        -> String?
    {
        guard var s = ptr.flatMap({ String(cString: $0) }), !s.isEmpty else {
            return nil
        }
        if stripLast {
            if s.last == "%" {
                s.removeLast()
            }
        }
        //        print(s)
        return s.isEmpty ? nil : s  // might become empty after %
    }

    let firstPart = clean(givenC, true)
    let lastPart = clean(familyC, true)

    // 2. Build Contacts predicate (if any). No compound predicate allowed
    var predicate: NSPredicate? = nil
    if let id = clean(idC) {
        predicate = CNContact.predicateForContacts(withIdentifiers: [id])
    } else if let phone = clean(phoneC) {
        //        print(phone)
        let num = CNPhoneNumber(stringValue: phone)
        predicate = CNContact.predicateForContacts(matching: num)
    } else if let f = firstPart, let l = lastPart {
        predicate = CNContact.predicateForContacts(matchingName: "\(f) \(l)")
    } else if let f = firstPart {
        predicate = CNContact.predicateForContacts(matchingName: f)
    } else if let l = lastPart {
        predicate = CNContact.predicateForContacts(matchingName: l)
    }  // else: no usable predicate → enumerate all

    //    print(predicate.debugDescription)

    // 3. Keys to fetch for projection push-down  (add flag vars)
    var keys: [CNKeyDescriptor] = []
    let needId = colMask & ContactsColMask.identifier != 0
    let needGiven = colMask & ContactsColMask.givenName != 0
    let needFamily = colMask & ContactsColMask.familyName != 0
    let needPhone = colMask & ContactsColMask.mainPhone != 0

    if needId {
        keys.append(CNContactIdentifierKey as CNKeyDescriptor)
    }
    if needGiven {
        keys.append(CNContactGivenNameKey as CNKeyDescriptor)
    }
    if needFamily {
        keys.append(CNContactFamilyNameKey as CNKeyDescriptor)
    }
    if needPhone {
        keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor)
    }
    if keys.isEmpty {
        keys = [CNContactIdentifierKey as CNKeyDescriptor]
    }

    // 4. Fetch contacts
    let store = CNContactStore()
    var ids: [String] = []
    var givenNames: [String] = []
    var familyNames: [String] = []
    var phones: [String] = []

    func append(_ c: CNContact) {
        // Always keep arrays the same length — use "" when the column was not requested.
        if needId {
            ids.append(c.identifier)
        } else {
            ids.append("")
        }

        if needGiven {
            givenNames.append(c.givenName)
        } else {
            givenNames.append("")
        }

        if needFamily {
            familyNames.append(c.familyName)
        } else {
            familyNames.append("")
        }

        if needPhone {
            let mainPhone = c.phoneNumbers.first?.value.stringValue ?? ""
            phones.append(mainPhone)
        } else {
            phones.append("")
        }
    }

    do {
        if let pred = predicate {
            let hits = try store.unifiedContacts(
                matching: pred,
                keysToFetch: keys
            )
            hits.forEach(append)
            print("Predicate pushdown")
        } else {
            let req = CNContactFetchRequest(keysToFetch: keys)
            try store.enumerateContacts(with: req) {
                c,
                _ in append(c)
            }
            //            print("in")
        }
    } catch {
        fatalError(error.localizedDescription)
    }

    // 5. Return snapshot to C
    let snap = ContactsHandle(
        ids: ids,
        givenNames: givenNames,
        familyNames: familyNames,
        phones: phones,
        mask: colMask
    )
    outHandle.pointee = ContactsHandlePtr(
        Unmanaged.passRetained(snap).toOpaque()
    )
    outCount.pointee = Int32(ids.count)
    return 0
}

// MARK: contacts_vtab_row ----------------------------------------------------
@_cdecl("contacts_vtab_row")
func contacts_vtab_row(
    _ handlePtr: ContactsHandlePtr?,
    _ rowIndex: Int32,
    _ outId: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ outGiven: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ outFamily: UnsafeMutablePointer<UnsafePointer<CChar>?>!,
    _ outPhone: UnsafeMutablePointer<UnsafePointer<CChar>?>!
) {
    guard let handlePtr = handlePtr else { return }
    let snap = Unmanaged<ContactsHandle>.fromOpaque(UnsafeRawPointer(handlePtr))
        .takeUnretainedValue()
    let i = Int(rowIndex)
    if i >= snap.ids.count { return }

    outId.pointee =
        (snap.mask & ContactsColMask.identifier != 0)
        ? dupCString(snap.ids[i])
        : nil

    outGiven.pointee =
        (snap.mask & ContactsColMask.givenName != 0)
        ? dupCString(snap.givenNames[i])
        : nil

    outFamily.pointee =
        (snap.mask & ContactsColMask.familyName != 0)
        ? dupCString(snap.familyNames[i])
        : nil

    outPhone.pointee =
        (snap.mask & ContactsColMask.mainPhone != 0 && !snap.phones[i].isEmpty)
        ? dupCString(snap.phones[i])
        : nil
}

// MARK: contacts_vtab_release ------------------------------------------------
@_cdecl("contacts_vtab_release")
func contacts_vtab_release(_ handlePtr: ContactsHandlePtr?) {
    if let handlePtr = handlePtr {
        Unmanaged<ContactsHandle>.fromOpaque(UnsafeRawPointer(handlePtr))
            .release()
    }
}
