//
//  EscrowAppApp.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import Photos
import SwiftUI

@main
struct EscrowAppApp: App {

    init() {

        // Run the heavy work off the main thread
        DispatchQueue.global(qos: .userInitiated).async(
            group: nil,
            qos: .userInitiated,
            flags: []
        ) {
            let contactsCount = Escrow.shared.run(
                access:
                    //                                        "SELECT identifier, givenName, familyName, mainPhoneNumber FROM Contacts"
                    //                    "SELECT familyName, givenName FROM Contacts"
                    //                     "SELECT givenName, familyName, mainPhoneNumber FROM Contacts LIMIT 5"
                    //                     "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE givenName = 'Zhiru'"
                    //                    "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE familyName LIKE 'Z%'"
                    //                     "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE familyName LIKE 'Z%' AND givenName = 'Zhiru'"
                    //                                        "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE givenName LIKE 'Z%' AND familyName = 'Zhu'"
                    //                    "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE givenName LIKE 'Z%' AND familyName LIKE 'Z%'"
                    //                "SELECT identifier, givenName, familyName, mainPhoneNumber FROM Contacts WHERE identifier = '8663BC28-0D1A-4C56-8B2E-CFEAAF5B5A83:ABPerson'"
                    //                    "SELECT identifier, givenName, familyName, mainPhoneNumber FROM Contacts WHERE mainPhoneNumber = '7739520990'"
                    "SELECT identifier, givenName, familyName, mainPhoneNumber FROM Contacts WHERE givenName LIKE 'Z%' AND familyName == 'Zhu' AND mainPhoneNumber = '7739520990' AND identifier = '8663BC28-0D1A-4C56-8B2E-CFEAAF5B5A83:ABPerson'"
            ) { rows in
                rows.forEach { row in
                    print(row)
                }
                return rows.count
            }
            print("Returned \(contactsCount) contacts rows\n")

            let photosCount = Escrow.shared.run(
                access:
                    //                    "SELECT identifier, collectionName, phasset FROM Photos"
                    //                    "SELECT identifier, collectionName, phasset FROM Photos LIMIT 1"
                    //                    "SELECT identifier, collectionName, phasset FROM Photos WHERE collectionName = 'escrowTest'"
                    //                "SELECT * FROM Photos WHERE mediaType = 1"
                    //                    "SELECT * FROM Photos WHERE mediaType = 1 AND identifier = '6A8AD8A5-8356-4A7A-BD20-760490DCBEED/L0/001'"
                    //                    "SELECT * FROM Photos WHERE mediaType = 1 AND identifier = '6A8AD8A5-8356-4A7A-BD20-760490DCBEED/L0/001'"
                    //                    "SELECT * FROM Photos WHERE mediaType = 1 AND identifier = '6A8AD8A5-8356-4A7A-BD20-760490DCBEED/L0/001'"
                    "SELECT * FROM Photos WHERE mediaType = 1 ORDER BY creationDate DESC LIMIT 1"
            ) { rows in
                rows.forEach { r in
                    let asset = r["phasset"] as! PHAsset
                    print(asset.debugDescription)
                    //                    if case let .phasset(a) = r["phasset"]! {
                    //                        print("  size:", a.pixelWidth, "×", a.pixelHeight)
                    //                    }
                }
                return rows.count
            }
            print("Returned \(photosCount) photos rows")

        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
