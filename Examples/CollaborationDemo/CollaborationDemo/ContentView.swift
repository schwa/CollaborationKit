//
//  ContentView.swift
//  CollaborationDemo
//
//  Created by Jonathan Wight.
//

import SwiftUI
import CollaborationKit

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("CollaborationDemo")
                .font(.headline)
            Text("Linked to CollaborationKit via local SPM.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .task {
            // Prove the module is linked and usable.
            let doc = InMemoryDocument("Hello.\n")
            _ = doc
        }
    }
}

#Preview {
    ContentView()
}