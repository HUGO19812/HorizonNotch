import AppKit
import Combine

/// Updates itself from the GitHub releases: no need to download the DMG by
/// hand. Every build on main publishes `latest.json` next to the DMG with
/// its build number; when it is higher than ours, the app offers the
/// update, downloads the DMG, swaps itself in /Applications and restarts.
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Decodable, Equatable {
        let version: String
        let build: Int
        let dmg: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available(Release), downloading, installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private static let feed = URL(string: "https://github.com/HUGO19812/HorizonNotch/releases/latest/download/latest.json")!
    private var timer: Timer?
    /// The build the user said "later" to; not asked again until a newer one.
    private var skippedBuild = 0

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// Checks shortly after launch and then every six hours.
    func start() {
        #if DEBUG || LOCAL_BUILD
        // Builds from Xcode or build.command are never replaced on their
        // own: their build number (1) is always below the released one, so
        // the release – maybe older code – would look like an update.
        return
        #else
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfEnabled() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkIfEnabled() }
        timer?.tolerance = 600
        #endif
    }

    private func checkIfEnabled() {
        guard AppSettings.shared.autoUpdateCheck else { return }
        check(userInitiated: false)
    }

    /// `userInitiated`: from the menu or settings – then also say when there
    /// is nothing new, and ask even for a build skipped before.
    func check(userInitiated: Bool) {
        if case .downloading = status { return }
        if case .installing = status { return }
        status = .checking
        var request = URLRequest(url: Self.feed)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let release else {
                    self.status = userInitiated ? .failed(L("Update-Server nicht erreichbar.", "Could not reach the update server.")) : .idle
                    return
                }
                guard release.build > Self.currentBuild else {
                    self.status = .upToDate
                    if userInitiated { self.tellUpToDate() }
                    return
                }
                self.status = .available(release)
                if userInitiated || release.build > self.skippedBuild { self.ask(release) }
            }
        }.resume()
    }

    // MARK: - Asking

    private func ask(_ release: Release) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Neue Version von Horizon Notch", "New version of Horizon Notch")
        alert.informativeText = L("Version \(release.version) (Build \(release.build)) ist da. Du hast Build \(Self.currentBuild). Jetzt installieren? Horizon Notch startet danach neu.",
                                  "Version \(release.version) (build \(release.build)) is available. You have build \(Self.currentBuild). Install now? Horizon Notch restarts afterwards.")
        alert.addButton(withTitle: L("Installieren", "Install"))
        alert.addButton(withTitle: L("Später", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            install(release)
        } else {
            skippedBuild = release.build
        }
    }

    private func tellUpToDate() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Horizon Notch ist aktuell", "Horizon Notch is up to date")
        alert.informativeText = L("Version \(Self.currentVersion) (Build \(Self.currentBuild)).",
                                  "Version \(Self.currentVersion) (build \(Self.currentBuild)).")
        alert.runModal()
    }

    // MARK: - Installing

    func install(_ release: Release) {
        status = .downloading
        URLSession.shared.downloadTask(with: release.dmg) { [weak self] location, _, error in
            guard let self else { return }
            guard let location else {
                self.fail(error?.localizedDescription ?? L("Download fehlgeschlagen.", "Download failed."))
                return
            }
            do {
                try self.installDownloadedDMG(at: location)
            } catch {
                self.fail(error.localizedDescription)
            }
        }.resume()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.status = .failed(message)
            let alert = NSAlert()
            alert.messageText = L("Update fehlgeschlagen", "Update failed")
            alert.informativeText = message
            alert.runModal()
        }
    }

    /// Runs on the download queue: mounts the DMG, copies the new app out,
    /// then hands over to a small script that swaps it in once we quit.
    private func installDownloadedDMG(at location: URL) throws {
        DispatchQueue.main.async { self.status = .installing }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("HorizonNotchUpdate-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("HorizonNotch.dmg")
        try manager.moveItem(at: location, to: dmg)

        let mount = work.appendingPathComponent("mount")
        try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                          "-mountpoint", mount.path])
        defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let mountedApp = mount.appendingPathComponent("HorizonNotch.app")
        let newApp = work.appendingPathComponent("HorizonNotch.app")
        try Self.run("/usr/bin/ditto", [mountedApp.path, newApp.path])

        // Only ever replace ourselves with the same app.
        guard let newBundle = Bundle(url: newApp),
              newBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError(L("Die heruntergeladene Datei ist keine Horizon Notch.", "The download is not Horizon Notch."))
        }

        let target = Bundle.main.bundleURL
        let script = work.appendingPathComponent("install.sh")
        let text = """
        #!/bin/bash
        # Waits for Horizon Notch to quit, swaps in the new version, starts it.
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "\(target.path)"
        /usr/bin/ditto "\(newApp.path)" "\(target.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
        /usr/bin/open "\(target.path)"
        /bin/rm -rf "\(work.path)"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((path as NSString).lastPathComponent) " + L("fehlgeschlagen", "failed") + " (\(process.terminationStatus))")
        }
        return process.terminationStatus
    }
}
