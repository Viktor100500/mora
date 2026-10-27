import Foundation

public struct CloudConfiguration: Codable, Equatable, Sendable {
    public var projectURL: URL
    public var publicKey: String
    public init(projectURL: URL, publicKey: String) throws {
        let host = projectURL.host ?? ""
        guard projectURL.scheme == "https", host.hasSuffix(".supabase.co"), host != "supabase.co",
              projectURL.user == nil, projectURL.password == nil, projectURL.port == nil,
              projectURL.query == nil, projectURL.fragment == nil, ["", "/"].contains(projectURL.path) else {
            throw LedgerError.invalid("Укажите адрес проекта вида https://имя-проекта.supabase.co.")
        }
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var isPublic = key.hasPrefix("sb_publishable_")
        if !isPublic {
            let parts = key.split(separator: ".")
            if parts.count == 3 {
                var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
                if let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    isPublic = claims["role"] as? String == "anon"
                }
            }
        }
        guard isPublic else { throw LedgerError.invalid("Нужен Publishable key (или прежний anon key). Secret и service_role ключи в приложение вводить нельзя.") }
        self.projectURL = projectURL; self.publicKey = key
    }
}

public struct CloudSession: Codable, Sendable {
    public struct User: Codable, Sendable { public let id: UUID; public let email: String? }
    public let access_token: String
    public let refresh_token: String
    public let expires_at: TimeInterval
    public let user: User
    private enum CodingKeys: String, CodingKey { case access_token, refresh_token, expires_at, expires_in, user }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access_token = try c.decode(String.self, forKey: .access_token)
        refresh_token = try c.decode(String.self, forKey: .refresh_token)
        expires_at = try c.decodeIfPresent(TimeInterval.self, forKey: .expires_at) ?? (Date().timeIntervalSince1970 + (try c.decode(TimeInterval.self, forKey: .expires_in)))
        user = try c.decode(User.self, forKey: .user)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(access_token, forKey: .access_token); try c.encode(refresh_token, forKey: .refresh_token)
        try c.encode(expires_at, forKey: .expires_at); try c.encode(user, forKey: .user)
    }
}

public struct CloudEnvelope: Codable, Sendable {
    public var household_id: UUID
    public var name: String
    public var version: Int64
    public var snapshot: Ledger
}
public struct CloudHousehold: Codable, Identifiable, Equatable, Sendable { public let id: UUID; public let name: String }
public struct CloudPhoneToken: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let account_id: UUID
    public let revoked: Bool
}
public struct CloudIssuedToken: Codable, Sendable { public let id: UUID; public let token: String }
/// An AI agent connected to the household through the remote MCP function.
public struct CloudAgentConnection: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let created_at: Date
    public let last_used_at: Date?
}
public extension CloudConfiguration {
    /// The MCP address for an agent key; the key in the path is the agent's only credential.
    func agentURL(token: String) -> URL {
        projectURL.appendingPathComponent("functions/v1/mora-mcp").appendingPathComponent(token)
    }
}
public struct CloudCapture: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let merchant: String
    public let amount: String
    public let currency: String
    public let account_id: UUID
    public let date: Date
    public let reason: String?
    public let label: String
    /// The Wallet trigger's "Card or Pass" text, when the iPhone sender passed it.
    public var card: String? = nil
    public var card_id: UUID? = nil
    public var card_linked: Bool? = nil
    /// A purchase from a card that has no account yet waits for the user's choice.
    public var awaitsCardLink: Bool { card_id != nil && card_linked != true }
}
/// A Wallet card seen by one phone key. `account_id == nil` means it is not linked yet.
public struct CloudWalletCard: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let card: String
    public let account_id: UUID?
    public let token_id: UUID
    public let label: String
    public let default_account_id: UUID
    public let last_seen: Date?
    public let pending_count: Int
}

public enum CloudAPIError: LocalizedError, Sendable {
    case unauthorized, response(Int, String), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Не удалось войти. Проверьте email и пароль; при истекшей сессии войдите повторно."
        case .invalidResponse: return "Облако вернуло неподдерживаемый ответ. Данные на Mac сохранены."
        case .response(let code, let detail):
            if code == 404 { return "Облачные функции не найдены. Сначала установите схему Mora в проекте Supabase." }
            if code == 403 { return "Нет доступа к общей базе или ключ отозван." }
            if code == 429 { return "Слишком много запросов. Повторите позже." }
            return "Ошибка облака (\(code)): \(detail)"
        }
    }
}

/// Foundation-only client: no backend secret, SDK, or external package in the app.
public struct CloudAPI: Sendable {
    public let configuration: CloudConfiguration
    private let transport: URLSession
    public init(configuration: CloudConfiguration, transport: URLSession = .shared) {
        self.configuration = configuration; self.transport = transport
    }

    public func signIn(email: String, password: String) async throws -> CloudSession {
        struct Body: Encodable { let email: String; let password: String }
        return try await request("auth/v1/token?grant_type=password", body: Body(email: email, password: password), accessToken: nil)
    }
    /// Needs "Allow anonymous sign-ins" in the project; used by iPhones paired with a Mac.
    public func signInAnonymously() async throws -> CloudSession {
        try await request("auth/v1/signup", body: ["data": [String: String]()], accessToken: nil)
    }
    public func refresh(_ token: String) async throws -> CloudSession {
        try await request("auth/v1/token?grant_type=refresh_token", body: ["refresh_token": token], accessToken: nil)
    }
    public func rpc<B: Encodable, R: Decodable>(_ function: String, _ body: B, accessToken: String) async throws -> R {
        try await request("rest/v1/rpc/" + function, body: body, accessToken: accessToken)
    }
    private func request<B: Encodable, R: Decodable>(_ path: String, body: B, accessToken: String?) async throws -> R {
        guard let url = URL(string: path, relativeTo: configuration.projectURL.appendingPathComponent("/"))?.absoluteURL else { throw CloudAPIError.invalidResponse }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(configuration.publicKey, forHTTPHeaderField: "apikey")
        if let accessToken { req.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(body)
        guard (req.httpBody?.count ?? 0) <= 4_000_000 else { throw LedgerError.invalid("Общая база больше 4 МБ. Синхронизация этой версии рассчитана на небольшую семейную базу.") }
        let (data, response) = try await transport.data(for: req)
        guard let response = response as? HTTPURLResponse, data.count <= 5_000_000 else { throw CloudAPIError.invalidResponse }
        if response.statusCode == 401 { throw CloudAPIError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let raw = object?["message"] as? String ?? object?["msg"] as? String ?? "Сервис недоступен. Повторите позже."
            throw CloudAPIError.response(response.statusCode, String(raw.prefix(300)))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(R.self, from: data) } catch { throw CloudAPIError.invalidResponse }
    }
}
