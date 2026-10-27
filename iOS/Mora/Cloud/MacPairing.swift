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
    enum Phase: Equatable {
        case searching, connecting(String), verifying(mac: String, code: String)
        case joining(mac: String, household: String), connected(String)
    }
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
                phase = .joining(mac: offer.device, household: invitation.householdName)
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
    func finish(_ household: String) { phase = .connected(household) }
    func fail(_ message: String) { error = message; phase = .searching }
    #if DEBUG
    /// `--pairing-preview searching|verifying|joining|connected` shows a stage without a Mac.
    func preview(_ stage: String) {
        switch stage {
        case "searching": macs = [Mac(name: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 1))]
        case "verifying": phase = .verifying(mac: "MacBook Pro", code: "482 913")
        case "joining": phase = .joining(mac: "MacBook Pro", household: "Семейный учет")
        case "connected": phase = .connected("Семейный учет")
        default: break
        }
    }
    #endif
}

struct MacPairingSheet: View {
    @EnvironmentObject private var store: FinanceStore
    @EnvironmentObject private var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = MacPairing()
    /// Runs after the Mac approves and before joining; onboarding creates the local file here.
    var prepare: () async -> Bool = { true }
    /// The project needs a regular sign-in; the cloud form is already prefilled.
    var needsSignIn: () -> Void = {}
    var finished: () -> Void = {}

    var body: some View {
        NavigationStack {
            ZStack {
                Color.moraBackground.ignoresSafeArea()
                PairingEdgeGlow(active: waitingForMac)
                Group {
                    switch pairing.phase {
                    case .searching: searching
                    case .connecting(let mac): exchange(mac: mac, title: L("Подключаемся к «\(mac)»…"), code: nil)
                    case .verifying(let mac, let code):
                        exchange(mac: mac, title: L("Проверьте, что на «\(mac)» показан тот же код, и нажмите «Разрешить» на Mac."), code: code)
                    case .joining(let mac, let household): exchange(mac: mac, title: L("Открываем общую базу «\(household)»…"), code: nil, fast: true)
                    case .connected(let household): connected(household)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: pairing.phase)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: pairing.macs)
            .navigationTitle(L("Подключиться к Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if currentHousehold.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(pairing.phase != .searching)
        .sensoryFeedback(.impact(weight: .medium), trigger: verificationCode)
        .sensoryFeedback(.success, trigger: currentHousehold)
        .onAppear {
            pairing.start()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--pairing-preview"), args.indices.contains(i + 1) { pairing.preview(args[i + 1]) }
            #endif
        }
        .onDisappear { pairing.stop() }
    }

    private var waitingForMac: Bool {
        switch pairing.phase {
        case .verifying, .joining: true
        default: false
        }
    }
    private var verificationCode: String? {
        if case .verifying(_, let code) = pairing.phase { return code }
        return nil
    }
    private var currentHousehold: String {
        if case .connected(let household) = pairing.phase { return household }
        return ""
    }

    private var searching: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    PairingRadar(active: true)
                    PairingDevice(symbol: "iphone")
                    ForEach(Array(pairing.macs.prefix(6).enumerated()), id: \.element.id) { index, mac in
                        let count = min(pairing.macs.count, 6)
                        let angle = -Double.pi / 4 + Double(index) * 2 * .pi / Double(count)
                        Button { Task { await request(mac) } } label: { PairingMacBubble(name: mac.name, index: index) }
                            .buttonStyle(.plain)
                            .offset(x: cos(angle) * 112, y: sin(angle) * 112)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                            .accessibilityLabel(L("Подключиться к «\(mac.name)»"))
                    }
                }
                .frame(width: 320, height: 320)
                VStack(spacing: 8) {
                    Text(pairing.macs.isEmpty ? L("Ищем Mac рядом…") : L("Выберите Mac")).font(.title3.weight(.semibold))
                    Text(L("Откройте Mora на Mac, подключенном к общей базе. Mac должен быть рядом или в той же сети Wi‑Fi."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if pairing.localNetworkDenied {
                    notice(L("Разрешите Mora доступ к локальной сети: Настройки → Конфиденциальность и безопасность → Локальная сеть."), icon: "wifi.exclamationmark")
                }
                if let error = pairing.error { notice(error, icon: "exclamationmark.triangle") }
                Text(L("Mac передаст по зашифрованному каналу адрес проекта, публичный ключ и приглашение. Данные этого iPhone будут заменены общей базой; перед заменой приложение сохранит резервную копию."))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 8)
            }
            .padding(24)
        }
    }

    private func exchange(mac: String, title: String, code: String?, fast: Bool = false) -> some View {
        VStack(spacing: 32) {
            Spacer()
            HStack(spacing: 12) {
                VStack(spacing: 8) { PairingDevice(symbol: "iphone", size: 76); Text(L("Этот iPhone")).font(.caption.weight(.semibold)) }
                PairingBeam(fast: fast)
                VStack(spacing: 8) {
                    PairingDevice(symbol: "laptopcomputer", size: 76)
                    Text(mac).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: 110)
            }
            VStack(spacing: 14) {
                if let code {
                    Text(L("Код для сверки")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    PairingCode(code: code)
                } else {
                    ProgressView().controlSize(.large).frame(height: 84)
                }
                Text(title).font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            }
            Spacer()
            if code != nil {
                Button(L("Отмена"), role: .cancel) { pairing.cancel() }.buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding(24)
    }

    private func connected(_ household: String) -> some View {
        VStack(spacing: 28) {
            Spacer()
            PairingBurst().frame(height: 200)
            VStack(spacing: 8) {
                Text(L("Подключено")).font(.largeTitle.weight(.bold))
                Text(L("iPhone подключен к «\(household)»")).font(.headline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            Spacer()
        }
        .padding(24)
    }

    private func notice(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.subheadline).foregroundStyle(.orange)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.moraCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func request(_ mac: MacPairing.Mac) async {
        guard let invitation = await pairing.request(mac) else { return }
        guard await prepare() else {
            pairing.fail(store.error ?? L("Не удалось подготовить данные iPhone."))
            store.error = nil
            return
        }
        if await cloud.connect(invitation) {
            pairing.finish(invitation.householdName)
            try? await Task.sleep(for: .seconds(2.6))
            store.showToast(L("iPhone подключен к «\(invitation.householdName)»"))
            finished()
            dismiss()
        } else if cloud.pairingPrefill != nil {
            needsSignIn()
            dismiss()
        } else {
            pairing.fail(cloud.error.map(L) ?? L("Не удалось подключиться к общей базе."))
            cloud.error = nil
        }
    }
}
