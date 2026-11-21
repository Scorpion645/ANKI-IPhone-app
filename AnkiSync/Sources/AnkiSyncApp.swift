import SwiftUI

@main
struct AnkiSyncApp: App {
    var body: some Scene {
        WindowGroup {
            AnkiSyncWebView()
                .ignoresSafeArea(.keyboard)
        }
    }
}

struct AnkiSyncWebView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AnkiSyncViewController {
        AnkiSyncViewController()
    }
    func updateUIViewController(_ uiViewController: AnkiSyncViewController, context: Context) {}
}
