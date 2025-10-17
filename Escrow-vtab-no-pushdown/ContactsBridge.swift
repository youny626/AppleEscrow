//
//  ContactsBridge.swift
//  EscrowApp
//
//  Created by XXX on 5/8/25.
//

import Contacts
import Foundation

// Snapshot returned to C as an opaque pointer
private final class ContactsHandle {
    let ids, givenNames, familyNames, phones: [String]
    init(
        ids: [String],
        givenNames: [String],
        familyNames: [String],
        phones: [String],
    ) {
        self.ids = ids
        self.givenNames = givenNames
        self.familyNames = familyNames
        self.phones = phones
    }
}

typealias ContactsHandlePtr = OpaquePointer

// Duplicate Swift String → malloc'ed C string so C side can free with free()
private func dupCString(_ str: String) -> UnsafePointer<CChar>? {
    guard let dup = strdup(str) else { return nil }
    return UnsafePointer<CChar>(dup)
}

@_cdecl("contacts_vtab_prepare")
func contacts_vtab_prepare(
    _ outHandle: UnsafeMutablePointer<ContactsHandlePtr?>!,
    _ outCount: UnsafeMutablePointer<Int32>!
) -> Int32 {

    let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    let store = CNContactStore()
    var ids: [String] = []
    var givenNames: [String] = []
    var familyNames: [String] = []
    var phones: [String] = []

    func append(_ c: CNContact) {
        ids.append(c.identifier)

        givenNames.append(c.givenName)

        familyNames.append(c.familyName)

        let mainPhone = c.phoneNumbers.first?.value.stringValue ?? ""
        phones.append(mainPhone)
    }

    do {
        let req = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: req) {
            c,
            _ in append(c)
        }

    } catch {
        fatalError(error.localizedDescription)
    }

    let snap = ContactsHandle(
        ids: ids,
        givenNames: givenNames,
        familyNames: familyNames,
        phones: phones,
    )
    outHandle.pointee = ContactsHandlePtr(
        Unmanaged.passRetained(snap).toOpaque()
    )
    outCount.pointee = Int32(ids.count)
    return 0
}

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

    outId.pointee = dupCString(snap.ids[i])

    outGiven.pointee = dupCString(snap.givenNames[i])

    outFamily.pointee = dupCString(snap.familyNames[i])

    outPhone.pointee = dupCString(snap.phones[i])
}

@_cdecl("contacts_vtab_release")
func contacts_vtab_release(_ handlePtr: ContactsHandlePtr?) {
    if let handlePtr = handlePtr {
        Unmanaged<ContactsHandle>.fromOpaque(UnsafeRawPointer(handlePtr))
            .release()
    }
}
