//
//  EscrowAppApp.swift
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

import SwiftUI
import Contacts

@main
struct EscrowAppApp: App {
    
    init() {
        let contactStore = CNContactStore()
        contactStore.requestAccess(for: .contacts) { granted, error in
            if granted {
                print("Contacts permission granted")
            } else {
                print("Contacts permission denied: \(error.debugDescription)")
            }
        }
        
        // Run the heavy work off the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let rowCount = Escrow.shared.run(
                access: "SELECT firstName, lastName, phoneNumbers FROM Contacts LIMIT 5"
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
