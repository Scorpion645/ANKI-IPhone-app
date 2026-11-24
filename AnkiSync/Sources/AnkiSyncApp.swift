import SwiftUI
import UIKit

@main
struct AnkiSyncApp: App {
    var body: some Scene {
        WindowGroup {
            if UIDevice.current.userInterfaceIdiom == .phone {
                // On iPhone, extend the web view edge to edge. The HTML
                // uses env(safe-area-inset-*) for the status bar and home bar.
                AnkiSyncWebView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                // Retain the existing iPad behavior and its safe-area layout.
                AnkiSyncWebView()
                    .ignoresSafeArea(.keyboard)
            }
        }
    }
}

struct AnkiSyncWebView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AnkiSyncViewController {
        AnkiSyncViewController()
    }
    func updateUIViewController(_ uiViewController: AnkiSyncViewController, context: Context) {}
}
