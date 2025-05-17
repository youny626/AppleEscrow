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
                    //                    "SELECT firstName, phoneNumbers FROM Contacts"
                                    "SELECT lastName, firstName FROM Contacts"
                    //                     "SELECT firstName, lastName, phoneNumbers FROM Contacts LIMIT 5"
                    //                     "SELECT firstName, lastName, phoneNumbers FROM Contacts WHERE firstName = 'Zhiru'"
                    //                    "SELECT firstName, lastName, phoneNumbers FROM Contacts WHERE lastName LIKE 'Z%'"
                    //                     "SELECT firstName, lastName, phoneNumbers FROM Contacts WHERE lastName LIKE 'Z%' AND firstName = 'Zhiru'"
//                    "SELECT firstName, lastName, phoneNumbers FROM Contacts WHERE firstName LIKE 'Z%' AND lastName = 'Zhu'"
                    //                    "SELECT firstName, lastName, phoneNumbers FROM Contacts WHERE firstName LIKE 'Z%' AND lastName LIKE 'Z%'"
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
