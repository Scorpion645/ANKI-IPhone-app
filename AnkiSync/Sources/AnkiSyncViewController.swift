import Foundation
import UIKit
import WebKit
import UniformTypeIdentifiers
import CryptoKit

/// Native file bridge for AnkiSync. All card/study UI remains the original HTML.
/// Native writes require a verified local recovery archive and SHA-256 conflict checks.
final class AnkiSyncViewController: UIViewController, WKScriptMessageHandler,
                                    UIDocumentPickerDelegate, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    // Pinned Ed25519 key: iCloud updates run ONLY if signed by the local publisher.
    private let updateSigningKey = "F6XHgY8yFvu8FG2IQUqiKf8hEIQWnKi6A1oBhkdXZ98="
    private let updateFolderName = "AnkiSync-Updates"
    private let updateHTMLName = "AnkiSync.html"
    private let updateSignatureName = "AnkiSync.sig"
    private let maxUpdateBytes = 8 * 1024 * 1024
    private let installedAppVersionKey = "AnkiSync.RuntimeBundledVersion.v1"
    private var hasLaunchedUpdateCheck = false
    private let bookmarkKey = "AnkiSync.iCloudFolderBookmark.v1"
    private var pendingPickerID: String?
    // Separate from the iCloud folder picker: manual Save As must open Files.
    private struct PendingExport {
        let name: String
        let declaredSize: Int
        var bytes = Data()
    }
    private var pendingExports: [String: PendingExport] = [:]
    private var pendingExportPickerID: String?
    private var pendingExportTempURL: URL?
    private let maxFileBytes = 512 * 1024 * 1024
    private let chunkLength = 96 * 1024 // smaller messages keep WKWebView responsive
    private let linkStorageKey = "AnkiSync.NativeFileLinks.v1"
    private struct PendingWrite {
        let deckId: String
        let path: String
        let expectedHash: String
        let declaredSize: Int
        var bytes = Data()
    }
    private var pendingWrites: [String: PendingWrite] = [:]
    // Immutable iCloud journal: independent event files, never an .apkg overwrite.
    private struct PendingJournalWrite {
        let key: String
        let name: String
        let size: Int
        var bytes = Data()
    }
    private var pendingJournalWrites: [String: PendingJournalWrite] = [:]
    private let maxJournalBytes = 64 * 1024 * 1024
    // Version pilot: isolated, immutable archives; never use linked-file writes.
    private let maxVersionBytes = 64 * 1024 * 1024
    private let maxVersionsPerDeviceDeck = 5
    private struct PendingVersion {
        let key: String
        let device: String
        let checkpoint: String
        let digest: String
        let size: Int
        var bytes = Data()
    }
    private var pendingVersion: (id: String, request: PendingVersion)?
    private var versionCommitBusy = false


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "AnkiNativeBridge")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        // The web view fills the entire native screen. Safe-area padding is
        // applied by the iPhone HTML UI (viewport-fit=cover), not by reducing
        // the height of the web view and leaving large unused black margins.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        // Emergency recovery if a validly signed future HTML release is broken:
        // a three-finger double-tap restores the trusted UI bundled in the IPA.
        let recoveryGesture = UITapGestureRecognizer(target: self, action: #selector(confirmBundledUIRestore))
        recoveryGesture.numberOfTapsRequired = 2
        recoveryGesture.numberOfTouchesRequired = 3
        recoveryGesture.cancelsTouchesInView = false
        webView.addGestureRecognizer(recoveryGesture)
        view.addSubview(webView)
        let isIPhone = UIDevice.current.userInterfaceIdiom == .phone
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: isIPhone ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: isIPhone ? view.bottomAnchor : view.safeAreaLayoutGuide.bottomAnchor)
        ])
        // Keep the HTML at one persistent URL across updates. Do not change
        // WKWebView's file origin every time the IPA receives a newer UI.
        do { try loadAppHTML() }
        catch { showError("AnkiSync could not prepare its local interface: " + error.localizedDescription) }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "AnkiNativeBridge", message.frameInfo.isMainFrame,
              webView.url?.isFileURL == true,
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
        // Manual Save As exports a NEW .apkg copy. It does not modify or
        // re-link any existing iCloud original, journal, or autosave record.
        // UIKit's document picker lets the user choose On My iPad / iCloud Drive.
        case "exportBegin":
            guard pendingExportPickerID == nil,
                  pendingExports.isEmpty,
                  let transferId = obj["transferId"] as? String,
                  !transferId.isEmpty,
                  let rawName = obj["filename"] as? String,
                  let size = obj["size"] as? Int,
                  (100...maxFileBytes).contains(size) else {
                reply(id, error: "An export is already open, or the package is invalid or too large.")
                return
            }
            let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
            let cleaned = String(String.UnicodeScalarView(rawName.unicodeScalars.map {
                forbidden.contains($0) ? "_".unicodeScalars.first! : $0
            })).trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.lowercased().hasSuffix(".apkg"),
                  cleaned.count <= 180, !cleaned.hasPrefix(".") else {
                reply(id, error: "Choose a valid .apkg filename.")
                return
            }
            pendingExports[transferId] = PendingExport(name: cleaned, declaredSize: size)
            reply(id, data: ["ready": true])
        case "exportChunk":
            guard let transferId = obj["transferId"] as? String,
                  let encoded = obj["data"] as? String,
                  let chunk = Data(base64Encoded: encoded),
                  chunk.count <= chunkLength * 2,
                  var transfer = pendingExports[transferId],
                  transfer.bytes.count + chunk.count <= transfer.declaredSize else {
                reply(id, error: "Invalid export chunk. No file was written.")
                return
            }
            transfer.bytes.append(chunk)
            pendingExports[transferId] = transfer
            reply(id, data: ["received": transfer.bytes.count])
        case "exportAbort":
            if let transferId = obj["transferId"] as? String {
                pendingExports.removeValue(forKey: transferId)
            }
            reply(id, data: ["aborted": true])
        case "exportCommit":
            guard pendingExportPickerID == nil,
                  let transferId = obj["transferId"] as? String,
                  let transfer = pendingExports.removeValue(forKey: transferId),
                  transfer.bytes.count == transfer.declaredSize else {
                reply(id, error: "Incomplete export; no file was saved.")
                return
            }
            do {
                // Unique temporary directory prevents a prior export from being
                // modified, and the Files provider controls final destination.
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AnkiSyncExports", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let source = dir.appendingPathComponent(transfer.name, isDirectory: false)
                try transfer.bytes.write(to: source, options: .atomic)
                let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
                picker.delegate = self
                pendingExportPickerID = id
                pendingExportTempURL = source
                present(picker, animated: true)
            } catch {
                reply(id, error: "Could not prepare .apkg for Save to Files: " + error.localizedDescription)
            }
        case "checkAppUpdate":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let report = try self.checkSignedUpdate()
                    DispatchQueue.main.async { self.reply(id, data: report) }
                } catch {
                    DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) }
                }
            }
        case "installAppUpdate":
            guard let expectedHash = obj["sha256"] as? String,
                  expectedHash.count == 64,
                  expectedHash.allSatisfy({ $0.isHexDigit }) else {
                reply(id, error: "Update verification is missing or invalid.")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let payload = try self.verifiedCloudUpdate()
                    guard self.hash(payload) == expectedHash else {
                        throw NativeError("The iCloud update changed since it was checked. Check again.")
                    }
                    try self.installSignedHTML(payload)
                    DispatchQueue.main.async {
                        self.reply(id, data: ["installed":true,"sha256":expectedHash])
                        // Reload only after the JS save request and reply have finished.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            try? self.loadAppHTML()
                        }
                    }
                } catch {
                    DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) }
                }
            }
        case "restoreBundledUI":
            // Manual emergency rollback: only the installed IPA's trusted UI is used.
            do {
                try restoreBundledHTML()
                reply(id, data: ["restored":true])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { try? self.loadAppHTML() }
            } catch {
                reply(id, error: error.localizedDescription)
            }
        case "status":
            let folder = bookmarkedFolder()
            let permitted = folder?.startAccessingSecurityScopedResource() ?? false
            if permitted { folder?.stopAccessingSecurityScopedResource() }
            reply(id, data: ["connected": permitted,
                             "folder": permitted ? (folder?.lastPathComponent ?? "") : "",
                             "links": permitted ? loadLinks() : [:]])
        case "versionCapabilities":
            reply(id, data: ["format":1,"maxBytes":maxVersionBytes,"maxVersions":maxVersionsPerDeviceDeck])
        case "versionCatalog":
            guard let key = obj["key"] as? String, let checkpoint = obj["checkpoint"] as? String else {
                reply(id, error: "Missing checkpoint identity"); return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                do { let entries = try self.catalogVersions(key: key, checkpoint: checkpoint)
                    DispatchQueue.main.async { self.reply(id, data: entries) }
                } catch { DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) } }
            }
        case "versionList":
            guard let key = obj["key"] as? String, let device = obj["device"] as? String else {
                reply(id, error: "Missing version identity"); return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                do { let names = try self.listVersions(key: key, device: device)
                    DispatchQueue.main.async { self.reply(id, data: names) }
                } catch { DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) } }
            }
        case "versionRead":
            guard let key = obj["key"] as? String, let device = obj["device"] as? String,
                  let name = obj["name"] as? String, self.validVersionName(name) else {
                reply(id, error: "Invalid version path"); return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                do { let bytes = try self.readVersion(key: key, device: device, name: name)
                    DispatchQueue.main.async { self.transferFile(id: id, name: name, data: bytes) }
                } catch { DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) } }
            }
        case "versionBegin":
            guard let key = obj["key"] as? String, let device = obj["device"] as? String,
                  let checkpoint = obj["checkpoint"] as? String, let digest = obj["sha256"] as? String,
                  let transferId = obj["transferId"] as? String, let size = obj["size"] as? Int,
                  size >= 100 && size <= maxVersionBytes,
                  pendingVersion == nil, !versionCommitBusy,
                  validVersionIdentity(key: key, device: device), validVersionDigest(checkpoint), validVersionDigest(digest) else {
                reply(id, error: "Version transfer busy, invalid, or exceeds 64 MiB"); return
            }
            pendingVersion = (transferId, PendingVersion(key: key, device: device, checkpoint: checkpoint, digest: digest, size: size))
            reply(id, data: ["ready":true])
        case "versionChunk":
            guard let transferId = obj["transferId"] as? String, var pending = pendingVersion,
                  pending.id == transferId, let encoded = obj["data"] as? String,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= chunkLength,
                  pending.request.bytes.count + bytes.count <= pending.request.size else {
                reply(id, error: "Invalid version chunk; no archive modified"); return
            }
            pendingVersion = nil
            pending.request.bytes.append(bytes); pendingVersion = pending
            reply(id, data: ["received":pending.request.bytes.count])
        case "versionAbort":
            if let transferId = obj["transferId"] as? String, pendingVersion?.id == transferId { pendingVersion = nil }
            reply(id, data: ["aborted":true])
        case "versionCommit":
            guard let transferId = obj["transferId"] as? String, let pending = pendingVersion,
                  pending.id == transferId, pending.request.bytes.count == pending.request.size, !versionCommitBusy else {
                reply(id, error: "Incomplete version transfer; no archive modified"); return
            }
            pendingVersion = nil; versionCommitBusy = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                do { let result = try self.writeVersion(pending.request)
                    DispatchQueue.main.async { self.versionCommitBusy = false; self.reply(id, data: result) }
                } catch { DispatchQueue.main.async { self.versionCommitBusy = false; self.reply(id, error: error.localizedDescription) } }
            }
        case "journalList":
            guard let key = obj["key"] as? String else { reply(id, error: "Missing journal key"); return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do { let names = try self.listJournal(key: key)
                    DispatchQueue.main.async { self.reply(id, data: names) }
                } catch { DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) } }
            }
        case "journalRead":
            guard let key = obj["key"] as? String, let name = obj["name"] as? String else {
                reply(id, error: "Missing journal record name"); return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do { let bytes = try self.readJournal(key: key, name: name)
                    DispatchQueue.main.async { self.transferFile(id: id, name: name, data: bytes) }
                } catch { DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) } }
            }
        case "journalBegin":
            guard let key = obj["key"] as? String, let name = obj["name"] as? String,
                  let transferId = obj["transferId"] as? String,
                  let size = obj["size"] as? Int, size > 0 && size <= maxJournalBytes,
                  pendingJournalWrites[transferId] == nil,
                  (try? journalRelativeURL(key: key, name: name)) != nil else {
                reply(id, error: "Journal record request is invalid or too large"); return
            }
            pendingJournalWrites[transferId] = PendingJournalWrite(key: key, name: name, size: size)
            reply(id, data: ["ready":true])
        case "journalChunk":
            guard let transferId = obj["transferId"] as? String,
                  let encoded = obj["data"] as? String,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= chunkLength * 2,
                  var pending = pendingJournalWrites[transferId],
                  pending.bytes.count + bytes.count <= pending.size else {
                reply(id, error: "Invalid journal data chunk; no file modified"); return
            }
            pending.bytes.append(bytes)
            pendingJournalWrites[transferId] = pending
            reply(id, data: ["received":pending.bytes.count])
        case "journalAbort":
            if let transferId = obj["transferId"] as? String { pendingJournalWrites.removeValue(forKey: transferId) }
            reply(id, data: ["aborted":true])
        case "journalCommit":
            guard let transferId = obj["transferId"] as? String,
                  let pending = pendingJournalWrites.removeValue(forKey: transferId),
                  pending.bytes.count == pending.size else {
                reply(id, error: "Incomplete journal transfer; no file modified"); return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do { let result = try self.writeJournal(pending)
                    DispatchQueue.main.async { self.reply(id, data: result) }
                } catch { DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) } }
            }
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
        case "linkFile":
            guard let deckId = obj["deckId"] as? String, !deckId.isEmpty,
                  let path = obj["path"] as? String else {
                reply(id, error: "A deck and its original path are required.")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.linkFile(deckId: deckId, path: path)
                    DispatchQueue.main.async { self.reply(id, data: result) }
                } catch {
                    DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) }
                }
            }
        case "renameFile":
            guard let deckId = obj["deckId"] as? String, !deckId.isEmpty,
                  let path = obj["path"] as? String,
                  let newName = obj["newName"] as? String else {
                reply(id, error: "A deck, existing original path and new filename are required.")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.renameDeckFile(deckId: deckId, path: path, newName: newName)
                    DispatchQueue.main.async { self.reply(id, data: result) }
                } catch {
                    DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) }
                }
            }
        case "exportRecovery":
            guard let deckId = obj["deckId"] as? String,
                  let record = loadLinks()[deckId],
                  let expectedHash = record["recoveryHash"],
                  let backupName = record["backup"],
                  let sourceName = record["name"] else {
                reply(id, error: "There is no linked recovery backup to export.")
                return
            }
            do {
                let url = try recoveryURL(deckId: deckId,
                    hash: expectedHash, sourceName: sourceName)
                guard url.lastPathComponent == backupName,
                      let bytes = try? Data(contentsOf: url),
                      hash(bytes) == expectedHash else {
                    throw NativeError("The recovery copy is missing or its checksum is incorrect.")
                }
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let popover = share.popoverPresentationController {
                    popover.sourceView = webView
                    popover.sourceRect = CGRect(x: webView.bounds.midX,
                                               y: webView.bounds.midY, width: 1, height: 1)
                }
                present(share, animated: true)
                reply(id, data: ["backup":backupName, "verified":true])
            } catch {
                reply(id, error: error.localizedDescription)
            }
        case "unlinkFile":
            guard let deckId = obj["deckId"] as? String else {
                reply(id, error: "Missing deck ID.")
                return
            }
            var links = loadLinks()
            links.removeValue(forKey: deckId)
            saveLinks(links)
            reply(id, data: ["unlinked": true])
        case "setPaused":
            guard let deckId = obj["deckId"] as? String,
                  let paused = obj["paused"] as? Bool else {
                reply(id, error: "Missing pause state.")
                return
            }
            var links = loadLinks()
            guard links[deckId] != nil else {
                reply(id, error: "Deck has no native file link.")
                return
            }
            links[deckId]?["paused"] = paused ? "1" : "0"
            saveLinks(links)
            reply(id, data: ["paused": paused])
        case "beginWrite":
            guard let deckId = obj["deckId"] as? String,
                  let path = obj["path"] as? String,
                  let expectedHash = obj["expectedHash"] as? String,
                  let transferId = obj["transferId"] as? String,
                  let size = obj["size"] as? Int,
                  (100...maxFileBytes).contains(size),
                  pendingWrites[transferId] == nil,
                  loadLinks()[deckId]?["path"] == path else {
                reply(id, error: "Invalid or unlinked write request. Original not modified.")
                return
            }
            pendingWrites[transferId] = PendingWrite(deckId: deckId,
                path: path, expectedHash: expectedHash, declaredSize: size)
            reply(id, data: ["ready": true])
        case "writeChunk":
            guard let transferId = obj["transferId"] as? String,
                  let encoded = obj["data"] as? String,
                  let data = Data(base64Encoded: encoded),
                  var transfer = pendingWrites[transferId],
                  data.count <= chunkLength * 2,
                  transfer.bytes.count + data.count <= transfer.declaredSize else {
                reply(id, error: "Invalid data chunk. Original not modified.")
                return
            }
            transfer.bytes.append(data)
            pendingWrites[transferId] = transfer
            reply(id, data: ["received": transfer.bytes.count])
        case "abortWrite":
            if let transferId = obj["transferId"] as? String { pendingWrites.removeValue(forKey: transferId) }
            reply(id, data: ["aborted": true])
        case "completeWrite":
            guard let transferId = obj["transferId"] as? String,
                  let transfer = pendingWrites.removeValue(forKey: transferId),
                  transfer.bytes.count == transfer.declaredSize else {
                reply(id, error: "Incomplete file transfer. Original not modified.")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.writeLinkedFile(transfer)
                    DispatchQueue.main.async { self.reply(id, data: result) }
                } catch {
                    DispatchQueue.main.async { self.reply(id, error: error.localizedDescription) }
                }
            }
        default:
            reply(id, error: "Unsupported native action.")
        }
    }

    // Without WKUIDelegate, WKWebView silently ignores JS confirm()/prompt().
    // This broke Delete, hard resets, selecting iCloud files, and other controls.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: "AnkiSync", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "AnkiSync", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Confirm", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: "AnkiSync", message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }

    private func cleanupExportTempFile() {
        guard let source = pendingExportTempURL else { return }
        pendingExportTempURL = nil
        // Give iCloud/File Provider time to consume the exported copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let id = pendingExportPickerID {
            pendingExportPickerID = nil
            cleanupExportTempFile()
            reply(id, error: "Save canceled. No file was exported.")
            return
        }
        if let id = pendingPickerID { reply(id, error: "Cancelled") }
        pendingPickerID = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        if let id = pendingExportPickerID {
            pendingExportPickerID = nil
            cleanupExportTempFile()
            guard let url = urls.first else {
                reply(id, error: "No save destination was selected.")
                return
            }
            reply(id, data: ["saved": true, "filename": url.lastPathComponent])
            return
        }
        guard let id = pendingPickerID else { return }
        pendingPickerID = nil
        guard let selected = urls.first else { reply(id, error: "No folder selected."); return }
        let previous = bookmarkedFolder()
        let accessed = selected.startAccessingSecurityScopedResource()
        defer { if accessed { selected.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            if previous?.standardizedFileURL != selected.standardizedFileURL {
                // Never keep a writable deck link when the authorized folder changes.
                saveLinks([:])
            }
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
                    // Recovery versions must never be offered as linked originals.
                    let relative = String(file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1))
                    if relative == "AnkiSync-Archive-Versions" || relative.hasPrefix("AnkiSync-Archive-Versions/") {
                        enumerator.skipDescendants(); continue
                    }
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

    // Journal keys and immutable filenames are deliberately narrower than deck paths.
    private func journalRelativeURL(key: String, name: String) throws -> String {
        let keyPattern = "^deck-[a-f0-9]{16}$"
        let eventPattern = "^device-[a-f0-9]{32}-[0-9]{10}\\.json$"
        guard key.range(of: keyPattern, options: .regularExpression) != nil,
              (name == "manifest.json" || name.range(of: eventPattern, options: .regularExpression) != nil) else {
            throw NativeError("Invalid AnkiSync journal key or record name")
        }
        return key + "/" + name
    }
    private func journalURL(_ folder: URL, key: String, name: String) throws -> URL {
        _ = try journalRelativeURL(key: key, name: name)
        return folder.appendingPathComponent("AnkiSync-Changes", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
    private func listJournal(key: String) throws -> [String] {
        try withFolder { folder in
            _ = try journalRelativeURL(key: key, name: "manifest.json")
            let dir = folder.appendingPathComponent("AnkiSync-Changes", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
            var coordinatorError: NSError?
            var names: [String] = []
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: dir, options: [], error: &coordinatorError) { url in
                names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { item in
                    (try? self.journalRelativeURL(key: key, name: item)) != nil
                }
            }
            if let error = coordinatorError { throw error }
            return names.sorted()
        }
    }
    private func readJournal(key: String, name: String) throws -> Data {
        try withFolder { folder in
            let target = try journalURL(folder, key: key, name: name)
            var error: NSError?
            var content: Data?
            var failure: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: target, options: [], error: &error) { url in
                do {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > self.maxJournalBytes { throw NativeError("Journal record exceeds 64 MB") }
                    content = try Data(contentsOf: url)
                } catch { failure = error }
            }
            if let error = error { throw error }
            if let failure = failure { throw failure }
            guard let content = content, content.count <= maxJournalBytes else {
                throw NativeError("iCloud journal record is not downloaded or accessible")
            }
            return content
        }
    }
    private func writeJournal(_ request: PendingJournalWrite) throws -> [String: Any] {
        try withFolder { folder in
            let dest = try journalURL(folder, key: request.key, name: request.name)
            let dir = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let digest = hash(request.bytes)
            // Immutable create-only: another device cannot accidentally overwrite a record.
            // The temp file is written completely before its final filename becomes visible.
            var coordinateError: NSError?
            var innerError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dir, options: .forMerging,
                error: &coordinateError) { targetDir in
                let target = targetDir.appendingPathComponent(request.name)
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        let old = try Data(contentsOf: target)
                        if self.hash(old) != digest { throw NativeError("Journal record already exists with different bytes. Sync stopped.") }
                        return
                    }
                    let temp = targetDir.appendingPathComponent(".ankisync-" + UUID().uuidString + ".tmp")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try request.bytes.write(to: temp, options: .atomic)
                    // FileManager.moveItem does not deliberately replace a destination.
                    if FileManager.default.fileExists(atPath: target.path) { throw NativeError("Journal record was created by another device; retry.") }
                    try FileManager.default.moveItem(at: temp, to: target)
                } catch { innerError = error }
            }
            if let error = coordinateError { throw error }
            if let error = innerError { throw error }
            let verified = try readJournal(key: request.key, name: request.name)
            guard hash(verified) == digest else { throw NativeError("Journal write verification failed. Sync stopped.") }
            return ["saved":true,"sha256":digest]
        }
    }

    // These paths are strictly constructed from journal/device IDs and hashes.
    private func validVersionIdentity(key: String, device: String) -> Bool {
        key.range(of: "^deck-[a-f0-9]{16}$", options: .regularExpression) != nil &&
        device.range(of: "^device-[a-f0-9]{32}$", options: .regularExpression) != nil
    }
    private func validVersionDigest(_ value: String) -> Bool {
        value.count == 64 && value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    private func validVersionName(_ name: String) -> Bool {
        name.range(of: "^checkpoint-[a-f0-9]{64}-[a-f0-9]{64}\\.apkg$", options: .regularExpression) != nil && name.count == 145
    }
    private func versionDirectory(_ root: URL, key: String, device: String) throws -> URL {
        guard validVersionIdentity(key: key, device: device) else { throw NativeError("Invalid version identity") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("AnkiSync-Archive-Versions", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true).appendingPathComponent(device, isDirectory: true)
        guard dir.resolvingSymlinksInPath().path == dir.path else { throw NativeError("Version directory is a symbolic link") }
        return dir
    }
    private func coordinatedVersionNames(_ dir: URL) throws -> [String] {
        var names: [String] = []; var failure: Error?; var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: dir, options: [], error: &coordinationError) { url in
            do { names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
            catch { failure = error }
        }
        if let error = coordinationError { throw error }; if let error = failure { throw error }
        return names
    }
    private func catalogVersions(key: String, checkpoint: String) throws -> [[String: String]] {
        guard validVersionDigest(checkpoint) else { throw NativeError("Invalid checkpoint") }
        return try withFolder { root in
            let dummy = "device-" + String(repeating: "0", count: 32)
            let dir = try versionDirectory(root, key: key, device: dummy).deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) { return [] }
            let devices = try coordinatedVersionNames(dir)
            var entries: [[String: String]] = []
            for device in devices where self.validVersionIdentity(key: key, device: device) {
                let child = try versionDirectory(root, key: key, device: device)
                guard (try child.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
                let names = try coordinatedVersionNames(child)
                for name in names where self.validVersionName(name) && name.hasPrefix("checkpoint-" + checkpoint + "-") {
                    entries.append(["device":device,"name":name])
                    if entries.count > 64 { throw NativeError("Too many matching archive versions") }
                }
            }
            return entries
        }
    }
    private func listVersions(key: String, device: String) throws -> [String] {
        try withFolder { root in
            let dir = try versionDirectory(root, key: key, device: device)
            if !FileManager.default.fileExists(atPath: dir.path) { return [] }
            var names: [String] = []; var failure: Error?; var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: dir, options: [], error: &coordinationError) { url in
                do { names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter(self.validVersionName).sorted() }
                catch { failure = error }
            }
            if let error = coordinationError { throw error }; if let error = failure { throw error }
            return names
        }
    }
    private func readVersionAt(_ url: URL, digest: String) throws -> Data {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw NativeError("Version file is a symbolic link") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let n = size.fileSize, n >= 100, n <= maxVersionBytes else { throw NativeError("Version unavailable or exceeds limit") }
        let data = try coordinatedRead(url)
        guard data.count == n, data.count <= maxVersionBytes, hash(data) == digest else { throw NativeError("Version checksum mismatch") }
        return data
    }
    private func readVersion(key: String, device: String, name: String) throws -> Data {
        guard validVersionName(name) else { throw NativeError("Invalid archive version name") }
        let digest = String(name.dropLast(5).suffix(64))
        return try withFolder { root in
            let dir = try versionDirectory(root, key: key, device: device)
            return try readVersionAt(dir.appendingPathComponent(name), digest: digest)
        }
    }
    private func writeVersion(_ request: PendingVersion) throws -> [String: Any] {
        guard validVersionIdentity(key: request.key, device: request.device), validVersionDigest(request.checkpoint),
              validVersionDigest(request.digest), request.bytes.count == request.size, request.size <= maxVersionBytes,
              request.size >= 100, request.bytes.prefix(4) == Data([0x50,0x4b,0x03,0x04]),
              hash(request.bytes) == request.digest else { throw NativeError("Invalid version bytes or SHA-256") }
        let name = "checkpoint-" + request.checkpoint + "-" + request.digest + ".apkg"
        guard validVersionName(name) else { throw NativeError("Invalid version filename") }
        return try withFolder { root in
            let dir = try versionDirectory(root, key: request.key, device: request.device)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var coordinateError: NSError?; var failure: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dir, options: .forMerging, error: &coordinateError) { targetDir in
                do {
                    let target = targetDir.appendingPathComponent(name)
                    let names = try FileManager.default.contentsOfDirectory(atPath: targetDir.path).filter(self.validVersionName)
                    if names.contains(name) { return } // verified below; no replacement
                    guard !names.contains(where: { $0.hasPrefix("checkpoint-" + request.checkpoint + "-") }) else {
                        throw NativeError("Checkpoint already has another version; verify it before retrying")
                    }
                    guard names.count < self.maxVersionsPerDeviceDeck else { throw NativeError("Version pilot limit reached; existing backups kept") }
                    let temp = targetDir.appendingPathComponent(".ankisync-version-" + UUID().uuidString + ".tmp")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try request.bytes.write(to: temp, options: .atomic)
                    guard !FileManager.default.fileExists(atPath: target.path) else { throw NativeError("Version already appeared; retry verification") }
                    try FileManager.default.moveItem(at: temp, to: target)
                } catch { failure = error }
            }
            if let error = coordinateError { throw error }; if let error = failure { throw error }
            let verified = try readVersionAt(dir.appendingPathComponent(name), digest: request.digest)
            guard verified.count == request.size else { throw NativeError("Version readback length differs") }
            return ["saved":true,"name":name,"sha256":request.digest,"size":verified.count]
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func loadLinks() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: linkStorageKey) as? [String: [String: String]] ?? [:]
    }
    private func saveLinks(_ links: [String: [String: String]]) {
        UserDefaults.standard.set(links, forKey: linkStorageKey)
    }
    private func recoveryURL(deckId: String, hash: String, sourceName: String) throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AnkiSync-Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeId = deckId.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let safeName = sourceName.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }
        return folder.appendingPathComponent(String(safeId.prefix(120)) + "_" + String(hash.prefix(16)) + "_" + String(safeName))
    }
    // The original package is backed up BEFORE a write can ever be enabled.
    // The recovery copy is separate in app storage, not within the source archive.
    private func verifiedRecovery(deckId: String, sourceName: String,
                                  bytes: Data, expectedHash: String) throws -> String {
        let url = try recoveryURL(deckId: deckId, hash: expectedHash, sourceName: sourceName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try bytes.write(to: url, options: .atomic)
        }
        let saved = try Data(contentsOf: url)
        guard saved.count == bytes.count && hash(saved) == expectedHash else {
            throw NativeError("Recovery backup verification failed. Autosave was not enabled.")
        }
        return url.lastPathComponent
    }

    private func linkFile(deckId: String, path: String) throws -> [String: Any] {
        let (name, bytes) = try readDeck(path: path)
        guard name.lowercased().hasSuffix(".apkg"), bytes.count >= 100,
              bytes.prefix(2) == Data([0x50, 0x4b]) else {
            throw NativeError("Please link a valid .apkg archive. Original was not modified.")
        }
        let digest = hash(bytes)
        let backup = try verifiedRecovery(deckId: deckId, sourceName: name,
                                         bytes: bytes, expectedHash: digest)
        // Confirm the file is still at exactly this version before recording the link.
        let (_, again) = try readDeck(path: path)
        guard hash(again) == digest else { throw NativeError("File changed while linking. Reconnect it before enabling autosave.") }
        var links = loadLinks()
        links[deckId] = ["path":path, "sha256":digest, "recoveryHash":digest,
                         "name":name, "backup":backup]
        saveLinks(links)
        return ["path":path, "sha256":digest, "name":name, "backup":backup]
    }

    // Renames only an existing .apkg in the previously authorized iCloud Anki
    // folder. Always creates a verified local recovery copy first. The operation
    // does not touch card data, journal events, or any similarly named file.
    private func renameDeckFile(deckId: String, path: String, newName: String) throws -> [String: Any] {
        let blocked = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        guard newName.utf8.count <= 205, newName.utf8.count > 5,
              newName.lowercased().hasSuffix(".apkg"),
              newName.rangeOfCharacter(from: blocked) == nil,
              !newName.hasPrefix("."), !newName.hasSuffix(" ") else {
            throw NativeError("The new .apkg filename contains unsupported characters.")
        }
        let stem = String(newName.dropLast(5)).uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
        guard !reserved.contains(stem), !stem.hasSuffix("."), !stem.hasSuffix(" ") else {
            throw NativeError("The destination filename is reserved on Windows.")
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/")
        guard !components.isEmpty, components.last.map(String.init)?.lowercased().hasSuffix(".apkg") == true else {
            throw NativeError("Select an existing .apkg original in the authorized Anki folder.")
        }
        let newPath = (components.dropLast().map(String.init) + [newName]).joined(separator: "/")
        guard normalized != newPath else { return ["ok": true, "path": newPath, "name": newName] }
        // Read the latest original under file coordination, and preserve it before renaming.
        let (sourceName, sourceData) = try readDeck(path: normalized)
        let digest = hash(sourceData)
        let backup = try verifiedRecovery(deckId: deckId, sourceName: sourceName,
                                          bytes: sourceData, expectedHash: digest)
        return try withFolder { folder in
            let source = try checkedPath(normalized, under: folder)
            let destination = try checkedPath(newPath, under: folder)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw NativeError("A file with that new name already exists. No files were renamed.")
            }
            var coordinationError: NSError?
            var operationError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: source, options: .forMoving,
                writingItemAt: destination, options: [], error: &coordinationError) { from, to in
                    do {
                        guard !FileManager.default.fileExists(atPath: to.path) else {
                            throw NativeError("The destination .apkg already exists; no overwrite permitted.")
                        }
                        let present = try Data(contentsOf: from)
                        guard self.hash(present) == digest else {
                            throw NativeError("The original changed while preparing to rename. Nothing was changed.")
                        }
                        try FileManager.default.moveItem(at: from, to: to)
                        let moved = try Data(contentsOf: to)
                        guard self.hash(moved) == digest else {
                            throw NativeError("File renamed but verification failed. Check both filenames before trying again.")
                        }
                    } catch { operationError = error }
                }
            if let error = operationError { throw error }
            if let error = coordinationError { throw error }
            // Preserve existing original-file autosave's verified source hash and
            // independent recovery backup, but update its URL to the new name.
            var links = loadLinks()
            if var link = links[deckId], link["path"] == normalized {
                link["path"] = newPath
                link["name"] = newName
                links[deckId] = link
                saveLinks(links)
            }
            return ["ok":true,"path":newPath,"name":newName,
                    "sha256":digest,"backup":backup]
        }
    }

    private func writeLinkedFile(_ request: PendingWrite) throws -> [String: Any] {
        let links = loadLinks()
        guard let record = links[request.deckId],
              record["path"] == request.path,
              record["sha256"] == request.expectedHash else {
            throw NativeError("File link changed. Autosave paused; original was not modified.")
        }
        guard request.bytes.count >= 100 && request.bytes.prefix(2) == Data([0x50, 0x4b]) else {
            throw NativeError("New data is not a ZIP/APKG archive. Original was not modified.")
        }
        let newHash = hash(request.bytes)
        let after = try withFolder { folder -> Data in
            let url = try checkedPath(request.path, under: folder)
            var coordinationError: NSError?
            var operationError: Error?
            var confirmed: Data?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do {
                    let old = try Data(contentsOf: target)
                    guard self.hash(old) == request.expectedHash else {
                        throw NativeError("Original changed in iCloud since linking. Autosave paused; no overwrite occurred.")
                    }
                    // The original recovery copy is immutable: never replace it
                    // with a later edited version on subsequent autosaves.
                    guard let firstHash = record["recoveryHash"],
                          let recoveryName = record["backup"] else {
                        throw NativeError("Missing recovery metadata. Original not modified.")
                    }
                    let initialURL = try self.recoveryURL(deckId: request.deckId,
                        hash: firstHash, sourceName: record["name"] ?? target.lastPathComponent)
                    guard initialURL.lastPathComponent == recoveryName,
                          let backupBytes = try? Data(contentsOf: initialURL),
                          self.hash(backupBytes) == firstHash else {
                        throw NativeError("Recovery copy is missing or changed. Original not modified.")
                    }
                    // Coordinated atomic replacement. If it fails, preserve the old file.
                    try request.bytes.write(to: target, options: .atomic)
                    let verified = try Data(contentsOf: target)
                    guard verified.count == request.bytes.count && self.hash(verified) == newHash else {
                        throw NativeError("iCloud readback verification failed. Original may be damaged; restore from the recovery backup before continuing.")
                    }
                    confirmed = verified
                } catch { operationError = error }
            }
            if let error = operationError { throw error }
            if let error = coordinationError { throw error }
            guard let data = confirmed else { throw NativeError("iCloud write could not be verified.") }
            return data
        }
        let verifiedHash = hash(after)
        guard verifiedHash == newHash else { throw NativeError("Verification failed after save. Autosave paused.") }
        var refreshed = loadLinks()
        // Do not overwrite a link that the user changed while this write was running.
        guard refreshed[request.deckId]?["sha256"] == request.expectedHash else {
            throw NativeError("The saved file was updated, but the link changed. Reconnect before saving again.")
        }
        refreshed[request.deckId]?["sha256"] = verifiedHash
        saveLinks(refreshed)
        return ["sha256":verifiedHash, "name":record["name"] ?? "", "size":after.count]
    }


    @objc private func confirmBundledUIRestore() {
        let alert = UIAlertController(title: "Restore AnkiSync interface?",
            message: "Return to the trusted interface bundled with this IPA? Your iCloud deck files are untouched. Export any unsaved changes before restoring.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Restore UI", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            do {
                try self.restoreBundledHTML()
                try self.loadAppHTML()
            } catch { self.showError("Could not restore UI: " + error.localizedDescription) }
        })
        present(alert, animated: true)
    }

    // MARK: Signed HTML updates from the same authorized iCloud folder as decks.
    // The original .apkg/.colpkg files are never inspected or modified by this updater.
    private func runtimeHTMLURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("AnkiSync-WebRuntime", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("AnkiSync.html")
    }

    private func bundledHTML() throws -> Data {
        guard let url = Bundle.main.url(forResource: "AnkiSync", withExtension: "html") else {
            throw NativeError("The bundled AnkiSync interface is missing.")
        }
        return try Data(contentsOf: url)
    }

    private func prepareRuntimeHTML() throws -> URL {
        let dest = try runtimeHTMLURL()
        let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        // Once per IPA upgrade, promote the newer trusted bundled UI to the stable
        // runtime path. A signed iCloud release can replace it again afterwards.
        if !FileManager.default.fileExists(atPath: dest.path) ||
                UserDefaults.standard.string(forKey: installedAppVersionKey) != bundleVersion {
            try bundledHTML().write(to: dest, options: .atomic)
            UserDefaults.standard.set(bundleVersion, forKey: installedAppVersionKey)
        }
        return dest
    }

    private func loadAppHTML() throws {
        let path = try prepareRuntimeHTML()
        webView.loadFileURL(path, allowingReadAccessTo: path.deletingLastPathComponent())
    }

    private func restoreBundledHTML() throws {
        let dest = try runtimeHTMLURL()
        try bundledHTML().write(to: dest, options: .atomic)
    }

    private func installSignedHTML(_ data: Data) throws {
        let dest = try runtimeHTMLURL()
        let previous = dest.deletingLastPathComponent().appendingPathComponent("AnkiSync.previous.html")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.copyItem(at: dest, to: previous)
        }
        // Replace at the stable URL; never write to the source in iCloud.
        try data.write(to: dest, options: .atomic)
        guard hash(try Data(contentsOf: dest)) == hash(data) else {
            if let old = try? Data(contentsOf: previous) { try? old.write(to: dest, options: .atomic) }
            throw NativeError("The downloaded UI failed verification. Previous UI restored.")
        }
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var error: NSError?
        var content: Data?
        var readError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { source in
            do { content = try Data(contentsOf: source) }
            catch { readError = error }
        }
        if let err = readError { throw err }
        if let err = error { throw err }
        guard let data = content else { throw NativeError("iCloud item is not downloaded or accessible.") }
        return data
    }

    private func verifiedCloudUpdate() throws -> Data {
        try withFolder { folder -> Data in
            let location = folder.appendingPathComponent(updateFolderName, isDirectory: true)
            let htmlURL = location.appendingPathComponent(updateHTMLName)
            let signatureURL = location.appendingPathComponent(updateSignatureName)
            guard FileManager.default.fileExists(atPath: htmlURL.path),
                  FileManager.default.fileExists(atPath: signatureURL.path) else {
                throw NativeError("No signed app update found in AnkiSync-Updates. Publish both AnkiSync.html and AnkiSync.sig.")
            }
            let html = try coordinatedRead(htmlURL)
            guard html.count >= 50000 && html.count <= maxUpdateBytes,
                  String(data: html.prefix(500), encoding: .utf8)?.contains("<!DOCTYPE html>") == true else {
                throw NativeError("The update is not a complete supported AnkiSync HTML file.")
            }
            let signatureText = try coordinatedRead(signatureURL)
            guard signatureText.count <= 1000,
                  let str = String(data: signatureText, encoding: .utf8),
                  let signature = Data(base64Encoded: str.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let publicRaw = Data(base64Encoded: updateSigningKey) else {
                throw NativeError("The iCloud app-update signature is invalid.")
            }
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: publicRaw)
            guard pub.isValidSignature(signature, for: html) else {
                throw NativeError("The iCloud update's signature does not match its HTML. The existing app was kept.")
            }
            return html
        }
    }

    private func checkSignedUpdate() throws -> [String: Any] {
        let data = try verifiedCloudUpdate()
        let newHash = hash(data)
        let current = try hash(Data(contentsOf: prepareRuntimeHTML()))
        return ["available":newHash != current,
                "sha256":newHash,
                "currentSHA256":current,
                "folder":"AnkiSync-Updates"]
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
