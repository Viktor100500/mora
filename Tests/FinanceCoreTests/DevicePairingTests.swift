import XCTest
import CryptoKit
import Network
@testable import FinanceCore

final class DevicePairingTests: XCTestCase {
    private let invitation = PairingInvitation(projectURL: URL(string: "https://example.supabase.co")!,
                                               publicKey: "sb_publishable_test", invitation: "code", householdName: "Дом")

    func testBothSidesDeriveTheSameCodeAndKey() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
        let phoneSide = try PairingSession(own: phone, peer: mac.publicKey.rawRepresentation, isPhone: true)
        let macSide = try PairingSession(own: mac, peer: phone.publicKey.rawRepresentation, isPhone: false)
        XCTAssertEqual(phoneSide.code, macSide.code)
        XCTAssertNotNil(phoneSide.code.wholeMatch(of: /\d{3} \d{3}/))
        let sealed = try macSide.seal(DevicePairing.Reply(invitation: invitation))
        XCTAssertEqual(try phoneSide.open(sealed, as: DevicePairing.Reply.self).invitation, invitation)
    }

    func testRelayedExchangeShowsDifferentCodesAndCannotOpen() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
        let relay = Curve25519.KeyAgreement.PrivateKey()
        let phoneSide = try PairingSession(own: phone, peer: relay.publicKey.rawRepresentation, isPhone: true)
        let macSide = try PairingSession(own: mac, peer: relay.publicKey.rawRepresentation, isPhone: false)
        XCTAssertNotEqual(phoneSide.code, macSide.code)
        XCTAssertThrowsError(try phoneSide.open(macSide.seal(DevicePairing.Reply(message: "x")), as: DevicePairing.Reply.self))
    }

    func testCommitmentBindsTheKey() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(DevicePairing.commitment(to: key), DevicePairing.commitment(to: key))
        XCTAssertNotEqual(DevicePairing.commitment(to: key), DevicePairing.commitment(to: other))
    }

    func testInvitationAcceptsOnlyPublicSupabaseConfiguration() {
        XCTAssertNoThrow(try invitation.configuration())
        var hostile = invitation; hostile.projectURL = URL(string: "https://evil.example.com")!
        XCTAssertThrowsError(try hostile.configuration())
    }

    /// Full handshake over loopback TCP, as the Mac listener and the iPhone run it.
    func testHandshakeOverLocalConnection() async throws {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: .any)
        let accepted = AsyncStream<NWConnection> { continuation in
            listener.newConnectionHandler = { continuation.yield($0) }
        }
        let ready = AsyncStream<NWEndpoint.Port> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0, let port = listener.port { continuation.yield(port) } }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var readyIterator = ready.makeAsyncIterator()
        let nextPort = await readyIterator.next()
        let port = try XCTUnwrap(nextPort)
        let invitation = self.invitation

        let mac = Task {
            var iterator = accepted.makeAsyncIterator()
            let channel = PairingChannel(await iterator.next()!)
            try await channel.open(timeout: 10)
            let hello = try await channel.receive(DevicePairing.Hello.self)
            let key = Curve25519.KeyAgreement.PrivateKey()
            try await channel.send(DevicePairing.Offer(version: 1, device: "Mac", key: key.publicKey.rawRepresentation))
            let reveal = try await channel.receive(DevicePairing.Reveal.self)
            XCTAssertEqual(DevicePairing.commitment(to: reveal.key), hello.commitment)
            let session = try PairingSession(own: key, peer: reveal.key, isPhone: false)
            try await channel.send(session.seal(DevicePairing.Reply(invitation: invitation)))
            return session.code
        }
        let channel = PairingChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await channel.open(timeout: 10)
        let key = Curve25519.KeyAgreement.PrivateKey()
        try await channel.send(DevicePairing.Hello(version: 1, device: "iPhone", commitment: DevicePairing.commitment(to: key.publicKey.rawRepresentation)))
        let offer = try await channel.receive(DevicePairing.Offer.self)
        try await channel.send(DevicePairing.Reveal(key: key.publicKey.rawRepresentation))
        let session = try PairingSession(own: key, peer: offer.key, isPhone: true)
        let reply = try session.open(try await channel.receive(DevicePairing.Sealed.self), as: DevicePairing.Reply.self)
        channel.cancel()
        let macCode = try await mac.value
        XCTAssertEqual(session.code, macCode)
        XCTAssertEqual(reply.invitation, invitation)
    }
}
