//
//  EscrowAppApp.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import SwiftUI

@main
struct EscrowAppApp: App {

    init() {

        // Run the heavy work off the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let rowCount = Escrow.shared.run(
                access:
                    //                                        "SELECT identifier, givenName, familyName, mainPhoneNumber FROM Contacts"
                    //                    "SELECT familyName, givenName FROM Contacts"
                    //                     "SELECT givenName, familyName, mainPhoneNumber FROM Contacts LIMIT 5"
                    //                     "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE givenName = 'Zhiru'"
                    //                    "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE familyName LIKE 'Z%'"
                    //                     "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE familyName LIKE 'Z%' AND givenName = 'Zhiru'"
                    //                    "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE givenName LIKE 'Z%' AND familyName = 'Zhu'"
                    //                    "SELECT givenName, familyName, mainPhoneNumber FROM Contacts WHERE givenName LIKE 'Z%' AND familyName LIKE 'Z%'"
                    //                "SELECT identifier, givenName, familyName, mainPhoneNumber FROM Contacts WHERE identifier = '8663BC28-0D1A-4C56-8B2E-CFEAAF5B5A83:ABPerson'"
                    "SELECT identifier, givenName, familyName, mainPhoneNumber FROM Contacts WHERE mainPhoneNumber = '7739520990'"
            ) { rows in
                rows.forEach { row in
                    print(row)
                }
                return rows.count
            }
            print("Returned \(rowCount) rows")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
