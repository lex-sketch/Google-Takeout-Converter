//
//  Takeout_CoverterApp.swift
//  Takeout Coverter
//
//  Created by Lex Mackey on 2/15/26.
//

import SwiftUI

@main
struct Takeout_CoverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        //instructions
        if #available(macOS 13.0, *) {
            Window("Instructions", id: "help") {
                Inst2()
                    .frame(minWidth: 300, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
            }
            .windowResizability(.contentSize)
        }
    }
}
