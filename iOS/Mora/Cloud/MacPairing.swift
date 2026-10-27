import SwiftUI
import CryptoKit
import Network
import FinanceCore

/// Finds Macs running Mora nearby and asks one of them for an invitation.
/// The Mac shows the same six-digit code and approves the request.
@MainActor
final class MacPairing: ObservableObject {
    struct Mac: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { "\(endpoint)" }
    }
    enum Phase: Equatable { case searching, connecting(String), verifying(mac: String, code: String), joining(String) }
    @Published private(set) var macs: [Mac] = []
    @Published private(set) var phase: Phase = .searching
    @Published private(set) var localNetworkDenied = false
    @Published var error: String?
    private var browser: NWBrowser?
    private var channel: PairingChannel?
    private var cancelled = false

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: DevicePairing.serviceType, domain: nil), using: DevicePairing.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Mac? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Mac(name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.macs = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            var denied = false
            if case .waiting(let error) = state, case .dns(let code) = error { denied = code == -65570 } // kDNSServiceErr_PolicyDenied
            Task { @MainActor in self?.localNetworkDenied = denied }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
    func stop() {
        browser?.cancel(); browser = nil
        cancel()
    }
    func cancel() {
        cancelled = true
        channel?.cancel()
    }

    /// The invitation once the Mac approves; nil after a refusal, a failure or `cancel()`.
    func request(_ mac: Mac) async -> PairingInvitation? {
        error = nil; cancelled = false; phase = .connecting(mac.name)
        let channel = PairingChannel(endpoint: mac.endpoint)
        self.channel = channel
        defer { channel.cancel(); if self.channel === channel { self.channel = nil } }
        do {
            try await channel.open(timeout: 180)
            let key = Curve25519.KeyAgreement.PrivateKey()
            try await channel.send(DevicePairing.Hello(version: DevicePairing.version, device: UIDevice.current.name,
                                                       commitment: DevicePairing.commitment(to: key.publicKey.rawRepresentation)))
            let offer = try await channel.receive(DevicePairing.Offer.self)
            guard offer.version == DevicePairing.version else { throw PairingError.unsupportedVersion }
            try await channel.send(DevicePairing.Reveal(key: key.publicKey.rawRepresentation))
            let session = try PairingSession(own: key, peer: offer.key, isPhone: true)
            phase = .verifying(mac: offer.device, code: session.code)
            let reply = try session.open(try await channel.receive(DevicePairing.Sealed.self), as: DevicePairing.Reply.self)
            if let invitation = reply.invitation {
                phase = .joining(invitation.householdName)
                return invitation
            }
            error = L(reply.message ?? "Mac не подтвердил подключение.")
        } catch {
            if !cancelled {
                self.error = (error as? PairingError).map { L($0.localizedDescription) }
                    ?? L("Не удалось связаться с Mac. Проверьте, что Mora на Mac открыта, а устройства рядом.")
            }
        }
        phase = .searching
        return nil
    }
}

struct MacPairingSheet: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = MacPairing()

    var body: some View {
        NavigationStack {
            List {
                switch pairing.phase {
                case .searching: searching
                case .connecting(let name):
                    Section { HStack(spacing: 12) { ProgressView(); Text(L("Подключаемся к «\(name)»…")) } }
                case .verifying(let mac, let code):
                    Section {
                        VStack(spacing: 14) {
                            Text(code).font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                                .accessibilityLabel(code.replacingOccurrences(of: " ", with: ""))
                            Text(L("Проверьте, что на «\(mac)» показан тот же код, и нажмите «Разрешить» на Mac."))
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                            ProgressView()
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    Section { Button(L("Отменить"), role: .destructive) { pairing.cancel() } }
                case .joining(let name):
                    Section { HStack(spacing: 12) { ProgressView(); Text(L("Открываем общую базу «\(name)»…")) } }
                }
            }
            .navigationTitle(L("Подключиться к Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } } }
        }
        .interactiveDismissDisabled(pairing.phase != .searching)
        .onAppear { pairing.start() }
        .onDisappear { pairing.stop() }
    }

    @ViewBuilder private var searching: some View {
        Section {
            if pairing.macs.isEmpty {
                HStack(spacing: 12) { ProgressView(); Text(L("Ищем Mac рядом…")).foregroundStyle(.secondary) }
            }
            ForEach(pairing.macs) { mac in
                Button { Task { await request(mac) } } label: { Label(mac.name, systemImage: "laptopcomputer") }
            }
        } header: { Text(L("Mac с Mora")) } footer: {
            Text(L("Откройте Mora на Mac, подключенном к общей базе. Mac должен быть рядом или в той же сети Wi‑Fi."))
        }
        if pairing.localNetworkDenied {
            Section {
                Label(L("Разрешите Mora доступ к локальной сети: Настройки → Конфиденциальность и безопасность → Локальная сеть."), systemImage: "wifi.exclamationmark")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        }
        if let error = pairing.error {
            Section { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) }
        }
        Section {
            Text(L("Mac передаст по зашифрованному каналу адрес проекта, публичный ключ и приглашение. Данные этого iPhone будут заменены общей базой; перед заменой приложение сохранит резервную копию."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func request(_ mac: MacPairing.Mac) async {
        guard let invitation = await pairing.request(mac) else { return }
        if await cloud.connect(invitation) { store.showToast(L("iPhone подключен к «\(invitation.householdName)»")) }
        // On failure the cloud screen shows the reason and, if needed, a prefilled sign-in form.
        dismiss()
    }
}
