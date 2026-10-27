import Foundation
import CryptoKit
import Network

/// What an approved Mac hands to an iPhone: enough to join the household with nothing typed.
public struct PairingInvitation: Codable, Equatable, Sendable {
    public var projectURL: URL
    public var publicKey: String
    public var invitation: String
    public var householdName: String
    public init(projectURL: URL, publicKey: String, invitation: String, householdName: String) {
        self.projectURL = projectURL; self.publicKey = publicKey; self.invitation = invitation; self.householdName = householdName
    }
    /// Rejects anything but a Supabase project URL and a publishable key, as manual entry does.
    public func configuration() throws -> CloudConfiguration { try CloudConfiguration(projectURL: projectURL, publicKey: publicKey) }
}

public enum PairingError: LocalizedError, Sendable {
    case closed, protocolViolation, commitmentMismatch, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .closed: return "Соединение с Mac прервано. Попробуйте еще раз."
        case .protocolViolation, .commitmentMismatch: return "Mac ответил некорректно. Подключение остановлено."
        case .unsupportedVersion: return "Обновите Mora на Mac и iPhone до одной версии."
        }
    }
}

/// Local-network pairing, like AirDrop: the iPhone finds a Mac over Bonjour,
/// both show the same six-digit code and the Mac's owner approves the request.
///
/// Phone → Mac: `Hello` with a hash commitment to its ephemeral X25519 key.
/// Mac → Phone: `Offer` with the Mac's key. Phone → Mac: `Reveal` of its key.
/// The commitment comes first, so a relay cannot pick keys that make both codes match.
/// The Mac's reply is sealed with ChaChaPoly under a key derived from the exchange.
public enum DevicePairing {
    public static let serviceType = "_mora-pair._tcp"
    public static let version = 1

    public struct Hello: Codable, Sendable {
        public var version: Int; public var device: String; public var commitment: Data
        public init(version: Int, device: String, commitment: Data) { self.version = version; self.device = device; self.commitment = commitment }
    }
    public struct Offer: Codable, Sendable {
        public var version: Int; public var device: String; public var key: Data
        public init(version: Int, device: String, key: Data) { self.version = version; self.device = device; self.key = key }
    }
    public struct Reveal: Codable, Sendable {
        public var key: Data
        public init(key: Data) { self.key = key }
    }
    public struct Sealed: Codable, Sendable { public var box: Data }
    /// Either an invitation or the reason the Mac declined.
    public struct Reply: Codable, Sendable {
        public var invitation: PairingInvitation?
        public var message: String?
        public init(invitation: PairingInvitation? = nil, message: String? = nil) { self.invitation = invitation; self.message = message }
    }

    public static func commitment(to key: Data) -> Data {
        Data(SHA256.hash(data: Data("mora-pairing-v1 commit".utf8) + key))
    }
    public static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        // Peer-to-peer Wi‑Fi lets nearby devices pair even on different networks.
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// The keys and code both devices derive once they have exchanged public keys.
public struct PairingSession: Sendable {
    /// Six digits, grouped for reading aloud: "123 456".
    public let code: String
    private let key: SymmetricKey

    public init(own: Curve25519.KeyAgreement.PrivateKey, peer: Data, isPhone: Bool) throws {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        let shared = try own.sharedSecretFromKeyAgreement(with: peerKey)
        let mine = own.publicKey.rawRepresentation
        let transcript = isPhone ? mine + peer : peer + mine
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("mora-pairing-v1 key".utf8), outputByteCount: 32)
        let codeKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("mora-pairing-v1 code".utf8), outputByteCount: 8)
        let number = codeKey.withUnsafeBytes { $0.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } } % 1_000_000
        let digits = String(format: "%06llu", number)
        code = digits.prefix(3) + " " + digits.suffix(3)
    }
    public func seal<T: Encodable>(_ value: T) throws -> DevicePairing.Sealed {
        let box = try ChaChaPoly.seal(JSONEncoder().encode(value), using: key)
        return DevicePairing.Sealed(box: box.combined)
    }
    public func open<T: Decodable>(_ sealed: DevicePairing.Sealed, as type: T.Type) throws -> T {
        let data = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed.box), using: key)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Length-prefixed JSON messages over one TCP connection.
public final class PairingChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mora.pairing.connection")
    private let lock = NSLock()
    private var closeHandler: (@Sendable () -> Void)?
    private var ready = false

    public init(_ connection: NWConnection) { self.connection = connection }
    public convenience init(endpoint: NWEndpoint) { self.init(NWConnection(to: endpoint, using: DevicePairing.parameters())) }

    /// Called once if the connection fails or closes after it was ready.
    public func onClose(_ handler: @escaping @Sendable () -> Void) { lock.withLock { closeHandler = handler } }

    /// Waits for the connection and closes it after `seconds`, so no step can hang.
    public func open(timeout seconds: Double) async throws {
        queue.asyncAfter(deadline: .now() + seconds) { [connection] in connection.cancel() }
        let resumed = Resumed()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.lock.withLock { self?.ready = true }
                        if resumed.claim() { continuation.resume() }
                    case .failed, .cancelled, .waiting:
                        if resumed.claim() {
                            if case .failed(let error) = state { continuation.resume(throwing: error) }
                            else if case .waiting(let error) = state { continuation.resume(throwing: error) }
                            else { continuation.resume(throwing: PairingError.closed) }
                        } else { self?.closed() }
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { [connection] in connection.cancel() }
    }
    public func cancel() { connection.cancel() }

    public func send<T: Encodable>(_ value: T) async throws {
        let body = try JSONEncoder().encode(value)
        var length = UInt32(body.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + body
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    public func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let header = try await read(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard (1...65_536).contains(length) else { throw PairingError.protocolViolation }
        do { return try JSONDecoder().decode(T.self, from: try await read(length)) }
        catch is DecodingError { throw PairingError.protocolViolation }
    }

    private func read(_ count: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, data.count == count { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: PairingError.closed) }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }
    private func closed() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard ready else { return nil }
            defer { closeHandler = nil }
            return closeHandler
        }
        handler?()
    }
}

private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
