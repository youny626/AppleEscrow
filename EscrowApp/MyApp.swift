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
                // "SELECT firstName, lastName, phoneNumbers FROM Contacts LIMIT 5"
                // "SELECT firstName, lastName, phoneNumbers FROM Contacts WHERE firstName = 'Yue'"
                access: "SELECT firstName, lastName, phoneNumbers FROM Contacts WHERE lastName LIKE 'G%' AND firstName = 'Yue'"
            ) { rows in
                rows.forEach { row in
                    if case let .text(fn)? = row["firstName"],
                       case let .text(ln)? = row["lastName"],
                       case let .text(ph)? = row["phoneNumbers"] {
                        print(fn, ln, "|", ph)
                    }
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
