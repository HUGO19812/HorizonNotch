import AppKit
import CryptoKit
import Network
import Security

/// Optional Spotify login (Settings → Music) for the heart: with it, a song
/// is saved to "Liked Songs" through the Web API – right away, also on the
/// lock screen, and the heart shows whether the song is liked. Without it,
/// the heart falls back to Spotify's shortcut (see SpotifyLikes).
///
/// Spotify gives no app-wide key: everyone registers their own app on
/// developer.spotify.com (needs Premium) with the redirect URI below and
/// enters its Client ID here. Login uses PKCE (no secret) with a
/// short-lived listener on that local port (Spotify's dashboard only takes
/// a loopback URI with a fixed port).
/// The refresh token stays in the keychain.
@MainActor
final class SpotifyAccount: ObservableObject {
    static let shared = SpotifyAccount()

    private static let port: UInt16 = 43827
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    private static let scopes = "user-library-modify user-library-read"
    private static let keychainService = "HorizonNotch.Spotify"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "spotifyClientID") }
    }
    @Published private(set) var isLoggedIn = false {
        didSet { if isLoggedIn != oldValue { NotificationCenter.default.post(name: Self.changed, object: nil) } }
    }
    /// Posted when the login comes or goes.
    nonisolated static let changed = Notification.Name("HorizonNotch.SpotifyLoginChanged")
    @Published private(set) var isLoggingIn = false
    /// Last problem, for Settings.
    @Published private(set) var problem: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var listener: NWListener?

    private init() {
        clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        isLoggedIn = Self.readRefreshToken() != nil
    }

    // MARK: Login

    func login() {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !isLoggingIn else { return }
        problem = nil
        isLoggingIn = true
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)
        do {
            let parameters = NWParameters.tcp
            // A second try right after the first must get the port again.
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection, verifier: verifier, state: state, clientID: id) }
            }
            listener.stateUpdateHandler = { [weak self] update in
                Task { @MainActor in
                    guard let self else { return }
                    switch update {
                    case .ready:
                        self.openAuthorization(clientID: id, challenge: challenge, state: state)
                    case .failed:
                        self.finishLogin(problem: L("Port \(Self.port) ist belegt – bitte später erneut versuchen.",
                                                    "Port \(Self.port) is in use – please try again later."))
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .main)
            // Give up after five minutes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self, self.listener === listener else { return }
                self.finishLogin(problem: L("Anmeldung abgelaufen.", "Login timed out."))
            }
        } catch {
            finishLogin(problem: error.localizedDescription)
        }
    }

    func logout() {
        Self.deleteRefreshToken()
        accessToken = nil
        expiry = .distantPast
        isLoggedIn = false
        problem = nil
    }

    private func openAuthorization(clientID: String, challenge: String, state: String) {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                                 URLQueryItem(name: "response_type", value: "code"),
                                 URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
                                 URLQueryItem(name: "code_challenge_method", value: "S256"),
                                 URLQueryItem(name: "code_challenge", value: challenge),
                                 URLQueryItem(name: "state", value: state),
                                 URLQueryItem(name: "scope", value: Self.scopes)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// The browser comes back with "GET /callback?code=…&state=…".
    private func receive(_ connection: NWConnection, verifier: String, state: String, clientID: String) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let query = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
            let code = query.first { $0.name == "code" }?.value
            let valid = target.hasPrefix("/callback") && query.first { $0.name == "state" }?.value == state
            let page = valid && code != nil
                ? L("Bei Spotify angemeldet. Du kannst dieses Fenster schließen.", "Signed in to Spotify. You can close this window.")
                : L("Anmeldung fehlgeschlagen.", "Login failed.")
            let body = "<html><body style=\"font:16px -apple-system;padding:40px\">\(page)</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            // Requests for other paths (a favicon) are ignored.
            guard target.hasPrefix("/callback") else { return }
            Task { @MainActor in
                guard let self, self.listener != nil else { return }
                guard valid, let code else {
                    self.finishLogin(problem: query.first { $0.name == "error" }?.value ?? L("Anmeldung fehlgeschlagen.", "Login failed."))
                    return
                }
                let ok = await self.requestToken(["grant_type": "authorization_code", "code": code,
                                                  "redirect_uri": Self.redirectURI,
                                                  "client_id": clientID, "code_verifier": verifier])
                self.finishLogin(problem: ok ? nil : L("Token nicht erhalten.", "No token received."))
            }
        }
    }

    private func finishLogin(problem: String?) {
        listener?.cancel()
        listener = nil
        isLoggingIn = false
        isLoggedIn = Self.readRefreshToken() != nil
        if let problem { self.problem = problem }
    }

    // MARK: Tokens

    /// Gets or renews the access token; nil when not logged in.
    private func validToken() async -> String? {
        if let accessToken, expiry > Date().addingTimeInterval(30) { return accessToken }
        guard let refresh = Self.readRefreshToken(), !clientID.isEmpty else { return nil }
        guard await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]) else {
            return nil
        }
        return accessToken
    }

    private func requestToken(_ form: [String: String]) async -> Bool {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            // Spotify refused the refresh token itself: logged out. (Network
            // trouble above keeps the login.)
            if form["grant_type"] == "refresh_token", status == 400 {
                Self.deleteRefreshToken()
                isLoggedIn = false
                problem = L("Anmeldung abgelaufen – bitte neu anmelden.", "Login expired – please sign in again.")
            }
            return false
        }
        accessToken = token
        expiry = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
        if let refresh = json["refresh_token"] as? String { Self.saveRefreshToken(refresh) }
        isLoggedIn = true
        return true
    }

    // MARK: Library

    /// Whether the track (a "spotify:track:…" URI) is in Liked Songs;
    /// nil when it can't be asked.
    func isSaved(_ uri: String) async -> Bool? {
        guard let data = await call("GET", path: "me/library/contains", uri: uri),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Bool] else { return nil }
        return values.first
    }

    /// Saves the track to Liked Songs or removes it; false on failure.
    func setSaved(_ uri: String, _ saved: Bool) async -> Bool {
        await call(saved ? "PUT" : "DELETE", path: "me/library", uri: uri) != nil
    }

    private func call(_ method: String, path: String, uri: String) async -> Data? {
        guard let token = await validToken() else { return nil }
        var components = URLComponents(string: "https://api.spotify.com/v1/" + path)!
        components.queryItems = [URLQueryItem(name: "uris", value: uri)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        guard (200..<300).contains(status) else {
            NSLog("[HorizonNotch] Spotify \(method) \(path): HTTP \(status)")
            if status == 403 {
                problem = L("Spotify hat abgelehnt (403) – ist dein Konto in der App unter „User Management“ eingetragen?",
                            "Spotify refused (403) – is your account listed under “User Management” in the app?")
            }
            return nil
        }
        return data
    }

    // MARK: Keychain

    private static func readRefreshToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveRefreshToken(_ token: String) {
        deleteRefreshToken()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: "refresh",
                                   kSecValueData as String: Data(token.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func deleteRefreshToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: keychainService] as CFDictionary)
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
