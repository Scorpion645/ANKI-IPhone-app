import Foundation
import UIKit
import WebKit
import UniformTypeIdentifiers

/// An intentionally read-only native bridge. All card/study UI is the original HTML.
/// Original .apkg overwriting is not enabled in this first iOS version.
final class AnkiSyncViewController: UIViewController, WKScriptMessageHandler,
                                    UIDocumentPickerDelegate, WKNavigationDelegate {
    private var webView: WKWebView!
    private let bookmarkKey = "AnkiSync.iCloudFolderBookmark.v1"
    private var pendingPickerID: String?
    private let maxFileBytes = 512 * 1024 * 1024
    private let chunkLength = 96 * 1024 // smaller messages keep WKWebView responsive

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "AnkiNativeBridge")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        guard let html = Bundle.main.url(forResource: "AnkiSync", withExtension: "html") else {
            showError("The bundled AnkiSync HTML was not found.")
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "AnkiNativeBridge",
              let obj = message.body as? [String: Any],
              let id = obj["id"] as? String,
              let action = obj["action"] as? String else { return }
        switch action {
        case "chooseFolder":
            if pendingPickerID != nil {
                reply(id, error: "A folder picker is already open.")
                return
            }
            pendingPickerID = id
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            present(picker, animated: true)
        case "status":
            let folder = bookmarkedFolder()
            reply(id, data: ["connected": folder != nil,
                             "folder": folder?.lastPathComponent ?? ""])
        case "listFiles":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let names = try self.listDeckFiles()
                    DispatchQueue.main.async { self.reply(id, data: names) }
                } catch {
                    DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) }
                }
            }
        case "readFile":
            guard let name = obj["path"] as? String else {
                reply(id, error: "Missing source filename.")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.readDeck(path: name)
                    DispatchQueue.main.async { self.transferFile(id: id, name: result.0, data: result.1) }
                } catch {
                    DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) }
                }
            }
        default:
            reply(id, error: "Unsupported native action.")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let id = pendingPickerID { reply(id, error: "Cancelled") }
        pendingPickerID = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let id = pendingPickerID else { return }
        pendingPickerID = nil
        guard let selected = urls.first else { reply(id, error: "No folder selected."); return }
        let accessed = selected.startAccessingSecurityScopedResource()
        defer { if accessed { selected.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            reply(id, data: ["folder": selected.lastPathComponent])
        } catch {
            reply(id, error: "Could not remember this folder: " + error.localizedDescription)
        }
    }

    private func bookmarkedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            if stale, let replacement = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(replacement, forKey: bookmarkKey)
            }
            return url
        } catch { return nil }
    }

    private func withFolder<T>(_ block: (URL) throws -> T) throws -> T {
        guard let folder = bookmarkedFolder() else {
            throw NativeError("Tap 'Connect iCloud Anki' and authorize your Anki folder once.")
        }
        guard folder.startAccessingSecurityScopedResource() else {
            throw NativeError("Saved iCloud folder permission expired. Tap 'Connect iCloud Anki' to authorize it again.")
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        return try block(folder)
    }

    private func checkedPath(_ relative: String, under folder: URL) throws -> URL {
        let path = relative.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              ["apkg", "colpkg"].contains(String(parts.last!).split(separator: ".").last?.lowercased() ?? "") else {
            throw NativeError("Only files inside the authorized folder ending in .apkg or .colpkg are supported.")
        }
        let root = folder.standardizedFileURL
        let target = parts.reduce(root) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw NativeError("Invalid deck file location.") }
        return target
    }

    private func readDeck(path: String) throws -> (String, Data) {
        try withFolder { folder in
            let requested = try checkedPath(path, under: folder)
            var coordinatorError: NSError?
            var result: Data?
            var readError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: requested, options: [], error: &coordinatorError) { url in
                do {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= self.maxFileBytes else { throw NativeError("This APKG exceeds the current 512 MB transfer limit.") }
                    result = try Data(contentsOf: url)
                } catch { readError = error }
            }
            if let error = readError { throw error }
            if let error = coordinatorError { throw error }
            guard let data = result else { throw NativeError("The iCloud file could not be downloaded or opened.") }
            guard data.count <= maxFileBytes else { throw NativeError("This APKG exceeds the current 512 MB transfer limit.") }
            return (requested.lastPathComponent, data)
        }
    }

    private func listDeckFiles() throws -> [String] {
        try withFolder { folder in
            var coordinatorError: NSError?
            var names: [String] = []
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: folder, options: [], error: &coordinatorError) { url in
                guard let enumerator = FileManager.default.enumerator(at: url,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
                for case let file as URL in enumerator {
                    guard ["apkg", "colpkg"].contains(file.pathExtension.lowercased()) else { continue }
                    let full = file.standardizedFileURL.path
                    let base = url.standardizedFileURL.path + "/"
                    if full.hasPrefix(base) { names.append(String(full.dropFirst(base.count))) }
                    if names.count >= 200 { break }
                }
            }
            if let error = coordinatorError { throw error }
            return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func transferFile(id: String, name: String, data: Data) {
        deliver(["kind":"start","id":id,"name":name,"size":data.count]) { [weak self] in
            self?.transferNextChunk(id: id, data: data, offset: 0)
        }
    }
    private func transferNextChunk(id: String, data: Data, offset: Int) {
        guard offset < data.count else {
            deliver(["kind":"complete","id":id]);return
        }
        let end = min(offset + chunkLength, data.count)
        let b64 = data.subdata(in: offset..<end).base64EncodedString()
        deliver(["kind":"chunk","id":id,"data":b64]) { [weak self] in
            self?.transferNextChunk(id: id, data: data, offset: end)
        }
    }
    private func reply(_ id: String, data: Any) {
        deliver(["kind":"result","id":id,"ok":true,"data":data])
    }
    private func reply(_ id: String, error: String) {
        deliver(["kind":"result","id":id,"ok":false,"error":error])
    }
    private func deliver(_ object: [String: Any], then: (() -> Void)? = nil) {
        guard JSONSerialization.isValidJSONObject(object),
              let bytes = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: bytes, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AnkiNative && window.AnkiNative.__deliver(\(json));") { _, error in
            if let error = error { NSLog("AnkiSync bridge error: %@", error.localizedDescription) }
            then?()
        }
    }
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "AnkiSync", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private struct NativeError: LocalizedError {
    let message: String
    init(_ text: String) { message = text }
    var errorDescription: String? { message }
}
