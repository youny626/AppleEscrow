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
                    //                    "SELECT givenName, phoneNumbers FROM Contacts"
                    //                    "SELECT familyName, givenName FROM Contacts"
                    //                     "SELECT givenName, familyName, phoneNumbers FROM Contacts LIMIT 5"
                    //                     "SELECT givenName, familyName, phoneNumbers FROM Contacts WHERE givenName = 'Zhiru'"
                    //                    "SELECT givenName, familyName, phoneNumbers FROM Contacts WHERE familyName LIKE 'Z%'"
                    //                     "SELECT givenName, familyName, phoneNumbers FROM Contacts WHERE familyName LIKE 'Z%' AND givenName = 'Zhiru'"
                    //                    "SELECT givenName, familyName, phoneNumbers FROM Contacts WHERE givenName LIKE 'Z%' AND familyName = 'Zhu'"
                    "SELECT givenName, familyName, phoneNumbers FROM Contacts WHERE givenName LIKE 'Z%' AND familyName LIKE 'Z%'"
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
