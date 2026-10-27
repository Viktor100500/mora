import SwiftUI
import AppKit
import CryptoKit
import Network
import FinanceCore

/// Answers "Connect to Mac" from iPhones nearby, like AirDrop: the Mac advertises
/// itself while it is connected to a household and asks before handing out an invitation.
@MainActor
final class PairingServer: ObservableObject {
    struct Request: Identifiable, Equatable { let id: UUID; let device: String; let code: String }
    @Published private(set) var request: Request?
    private var listener: NWListener?
    private weak var cloud: CloudSync?
    private var decision: CheckedContinuation<Bool, Never>?
    private var handling = false

    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    func update(active: Bool, cloud: CloudSync) {
        self.cloud = cloud
        if active { if listener == nil { start() } }
        else {
            listener?.cancel(); listener = nil
            if let request { answer(request.id, approved: false) }
        }
    }
    func answer(_ id: UUID, approved: Bool) {
        guard request?.id == id, let decision else { return }
        self.decision = nil; request = nil
        decision.resume(returning: approved)
    }

    private func start() {
        guard let listener = try? NWListener(using: DevicePairing.parameters()) else { return }
        listener.service = NWListener.Service(name: Self.deviceName, type: DevicePairing.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in await self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            // The network changed under the listener (sleep, Wi‑Fi switch): advertise again.
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                listener.cancel(); self.listener = nil
                try? await Task.sleep(for: .seconds(5))
                if self.listener == nil, let cloud = self.cloud { self.update(active: cloud.signedIn && cloud.householdID != nil, cloud: cloud) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) async {
        let channel = PairingChannel(connection)
        // One request at a time; others are simply refused.
        guard !handling, let cloud else { channel.cancel(); return }
        handling = true
        defer { handling = false; channel.cancel() }
        do {
            try await channel.open(timeout: 180)
            let hello = try await channel.receive(DevicePairing.Hello.self)
            guard hello.version == DevicePairing.version else { return }
            let key = Curve25519.KeyAgreement.PrivateKey()
            try await channel.send(DevicePairing.Offer(version: DevicePairing.version, device: Self.deviceName, key: key.publicKey.rawRepresentation))
            let reveal = try await channel.receive(DevicePairing.Reveal.self)
            guard DevicePairing.commitment(to: reveal.key) == hello.commitment else { throw PairingError.commitmentMismatch }
            let session = try PairingSession(own: key, peer: reveal.key, isPhone: false)
            let device = String(hello.device.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            let approved = await ask(device: device.isEmpty ? "iPhone" : device, code: session.code, channel: channel)
            let reply: DevicePairing.Reply
            if !approved { reply = .init(message: "Подключение отклонено на Mac.") }
            else if let invitation = await cloud.pairingInvitation() { reply = .init(invitation: invitation) }
            else { reply = .init(message: cloud.error ?? "Mac не смог создать приглашение. Попробуйте еще раз.") }
            try await channel.send(session.seal(reply))
            // Give the iPhone time to read the reply before the connection closes.
            try? await Task.sleep(for: .seconds(2))
        } catch {}
    }

    private func ask(device: String, code: String, channel: PairingChannel) async -> Bool {
        let id = UUID()
        channel.onClose { Task { @MainActor [weak self] in self?.answer(id, approved: false) } }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            self?.answer(id, approved: false)
        }
        defer { timeout.cancel() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.requestUserAttention(.criticalRequest)
        return await withCheckedContinuation { continuation in
            decision = continuation
            request = Request(id: id, device: device, code: code)
        }
    }
}

/// The approval prompt, shown over the main window.
struct PairingPrompt: ViewModifier {
    @ObservedObject var pairing: PairingServer
    @ObservedObject var cloud: CloudSync
    @ObservedObject var store: FinanceStore
    private var active: Bool { cloud.signedIn && cloud.householdID != nil && !store.isDemo }
    func body(content: Content) -> some View {
        content
            .onAppear { pairing.update(active: active, cloud: cloud) }
            .onChange(of: active) { _, value in pairing.update(active: value, cloud: cloud) }
            .alert(L("iPhone хочет подключиться"), isPresented: Binding(get: { pairing.request != nil }, set: { _ in }), presenting: pairing.request) { request in
                Button(L("Разрешить")) { pairing.answer(request.id, approved: true) }
                Button(L("Отклонить"), role: .cancel) { pairing.answer(request.id, approved: false) }
            } message: { request in
                Text(L("«\(request.device)» просит доступ к общей базе «\(cloud.householdName)». Разрешайте, только если на iPhone показан тот же код: \(request.code)"))
            }
    }
}
