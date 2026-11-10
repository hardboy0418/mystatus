import CoreWLAN
import Foundation
import SystemConfiguration

struct WiFiServiceNetworkConfiguration {
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]
    let router: String?
    let dnsServers: [String]

    static let unavailable = Self(ipv4Addresses: [], ipv6Addresses: [], router: nil, dnsServers: [])

    /// The Wi-Fi link's addresses. Service selection lives in
    /// `NetworkServiceResolver`, which the wired link resolves through as well,
    /// so both links pick a service by the same rule.
    static func resolve(interface: String, snapshot: [String: [String: Any]]) -> Self {
        guard let configuration = NetworkServiceResolver.resolve(
            interface: interface,
            snapshot: snapshot
        ) else {
            return .unavailable
        }
        return Self(
            ipv4Addresses: configuration.ipv4Addresses,
            ipv6Addresses: configuration.ipv6Addresses,
            router: configuration.router,
            dnsServers: configuration.dnsServers
        )
    }
}

struct WiFiScanPayload: Sendable {
    let networks: [WiFiNetwork]
    let details: WiFiConnectionDetails
}

enum WiFiScanWorkerResult: Sendable {
    case success(WiFiScanPayload)
    case poweredOff
    case noInterface
    case failed
}

/// The scan and power calls the network list needs. CoreWLAN is synchronous and
/// serialized on the worker's own queue; the protocol exists so a test can
/// answer instantly and count the scans, which is how the cadence is observable
/// without sweeping every channel.
protocol WiFiNetworkScanning: AnyObject {
    func scan(completion: @escaping @Sendable (WiFiScanWorkerResult) -> Void)
    func readBasicDetails(completion: @escaping @Sendable (WiFiScanWorkerResult) -> Void)
    func setPower(_ isOn: Bool, completion: @escaping @Sendable (Bool) -> Void)
    func associate(
        to network: WiFiNetwork,
        password: String?,
        completion: @escaping @Sendable (WiFiAssociationWorkerResult) -> Void
    )
}

extension WiFiNetworkScanning {
    func readBasicDetails(completion: @escaping @Sendable (WiFiScanWorkerResult) -> Void) {
        completion(.success(WiFiScanPayload(networks: [], details: .unavailable)))
    }

    /// Default so existing scan-only test doubles keep compiling; a double
    /// that exercises the join flow implements it for real.
    func associate(
        to _: WiFiNetwork,
        password _: String?,
        completion: @escaping @Sendable (WiFiAssociationWorkerResult) -> Void
    ) {
        completion(.failed)
    }
}

/// CoreWLAN exposes synchronous scan APIs. This worker owns a serial queue so
/// those calls never run on the main actor and cannot overlap.
private final class CoreWLANNetworkWorker: @unchecked Sendable, WiFiNetworkScanning {
    private let queue = DispatchQueue(label: "StatusTrio.CoreWLANNetworkWorker")
    private let knownNetworkProvider: any WiFiKnownNetworkProviding

    init(
        knownNetworkProvider: any WiFiKnownNetworkProviding = NetworksetupWiFiKnownNetworkProvider()
    ) {
        self.knownNetworkProvider = knownNetworkProvider
    }

    func scan(completion: @escaping @Sendable (WiFiScanWorkerResult) -> Void) {
        queue.async { [self] in
            completion(scanSynchronously())
        }
    }

    func readBasicDetails(completion: @escaping @Sendable (WiFiScanWorkerResult) -> Void) {
        queue.async { [self] in completion(scanSynchronously(includeIdentity: false)) }
    }

    func setPower(
        _ isOn: Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async {
            guard let interface = CWWiFiClient.shared().interface() else {
                completion(false)
                return
            }
            do {
                try interface.setPower(isOn)
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    func associate(
        to network: WiFiNetwork,
        password: String?,
        completion: @escaping @Sendable (WiFiAssociationWorkerResult) -> Void
    ) {
        queue.async { [self] in
            completion(associateSynchronously(to: network, password: password))
        }
    }

    private func associateSynchronously(
        to selected: WiFiNetwork,
        password: String?
    ) -> WiFiAssociationWorkerResult {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            return .networkUnavailable
        }
        guard let targetBSSID = selected.preferredCandidate?.bssid else {
            return .networkUnavailable
        }

        do {
            let networks = try interface.scanForNetworks(withSSID: nil)
            guard let target = networks.first(where: {
                $0.ssid == selected.ssid
                    && securityKind(for: $0) == selected.security
                    && bssid($0.bssid, matches: targetBSSID)
            }) else {
                return .networkUnavailable
            }

            // Do not disassociate first: CoreWLAN is asked to associate directly
            // with the selected AP and macOS retains the prior association until
            // it has progressed the new request.
            try interface.associate(to: target, password: password)

            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                if isAssociated(interface: interface, with: selected, targetBSSID: targetBSSID) {
                    let actualNetwork = (try? interface.scanForNetworks(withSSID: selected.ssid.data(using: .utf8)))?
                        .first { bssid($0.bssid, matches: interface.bssid()) }
                    return .success(makeDetails(interface: interface, actualNetwork: actualNetwork ?? target))
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return .timedOut
        } catch {
            // CoreWLAN does not provide a stable public error taxonomy for all
            // authentication failures, so do not guess that this was a bad
            // password. The UI presents an accurate generic failure instead.
            return .failed
        }
    }

    private func isAssociated(
        interface: CWInterface,
        with selected: WiFiNetwork,
        targetBSSID: String
    ) -> Bool {
        if bssid(interface.bssid(), matches: targetBSSID) { return true }
        guard interface.ssid() == selected.ssid else { return false }
        return compatibleSecurity(
            WiFiSecurityKind(coreWLANRawValue: interface.security().rawValue),
            selected.security
        )
    }

    private func compatibleSecurity(_ lhs: WiFiSecurityKind, _ rhs: WiFiSecurityKind) -> Bool {
        guard lhs != .unknown, rhs != .unknown else { return false }
        if lhs == rhs { return true }
        let personalModes: Set<WiFiSecurityKind> = [
            .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal,
            .wpa3Personal, .wpa3Transition
        ]
        return personalModes.contains(lhs) && personalModes.contains(rhs)
    }

    private func scanSynchronously(includeIdentity: Bool = true) -> WiFiScanWorkerResult {
        guard let interface = CWWiFiClient.shared().interface() else { return .noInterface }
        guard interface.powerOn() else { return .poweredOff }

        if !includeIdentity {
            return .success(WiFiScanPayload(
                networks: [],
                details: makeDetails(interface: interface, actualNetwork: nil, includeIdentity: false)
            ))
        }
        do {
            let rawNetworks = try interface.scanForNetworks(withSSID: nil)
            let associatedBSSID = interface.bssid()
            let candidates = rawNetworks.compactMap(projectCandidate)
            let knownSSIDs = interface.interfaceName.map {
                knownNetworkProvider.preferredNetworkSSIDs(interface: $0)
            } ?? []
            let actualNetwork = rawNetworks.first {
                bssid($0.bssid, matches: associatedBSSID)
            }
            return .success(
                WiFiScanPayload(
                    networks: WiFiNetwork.merge(
                        candidates,
                        connectedBSSID: associatedBSSID,
                        knownSSIDs: knownSSIDs
                    ),
                    details: makeDetails(interface: interface, actualNetwork: actualNetwork)
                )
            )
        } catch {
            return .failed
        }
    }

    private func securityKind(for network: CWNetwork) -> WiFiSecurityKind {
        let preferredKinds: [(CWSecurity, WiFiSecurityKind)] = [
            (.wpa3Transition, .wpa3Transition),
            (.wpa3Enterprise, .wpa3Enterprise),
            (.wpa3Personal, .wpa3Personal),
            (.oweTransition, .oweTransition),
            (.OWE, .owe),
            (.wpa2Enterprise, .wpa2Enterprise),
            (.wpaEnterpriseMixed, .wpaEnterpriseMixed),
            (.wpaEnterprise, .wpaEnterprise),
            (.enterprise, .enterprise),
            (.wpa2Personal, .wpa2Personal),
            (.wpaPersonalMixed, .wpaPersonalMixed),
            (.wpaPersonal, .wpaPersonal),
            (.personal, .personal),
            (.dynamicWEP, .dynamicWEP),
            (.WEP, .wep),
            (.none, .open)
        ]
        return preferredKinds.first { network.supportsSecurity($0.0) }?.1 ?? .unknown
    }

    private func projectCandidate(_ network: CWNetwork) -> WiFiNetworkCandidate? {
        guard let ssid = network.ssid else { return nil }
        return WiFiNetworkCandidate(
            ssid: ssid,
            bssid: network.bssid,
            rssi: normalizedMeasurement(network.rssiValue),
            channel: network.wlanChannel?.channelNumber,
            security: securityKind(for: network)
        )
    }

    private func makeDetails(
        interface: CWInterface,
        actualNetwork: CWNetwork?,
        includeIdentity: Bool = true
    ) -> WiFiConnectionDetails {
        let interfaceName = interface.interfaceName
        let configuration = interfaceName.map(networkConfiguration(interface:)) ?? .unavailable
        let channel = interface.wlanChannel()
        let transmitRate = interface.transmitRate()

        return WiFiConnectionDetails(
            ssid: includeIdentity ? interface.ssid() : nil,
            bssid: includeIdentity ? interface.bssid() : nil,
            band: displayBand(channel?.channelBand.rawValue),
            channel: channel?.channelNumber,
            channelWidth: displayChannelWidth(channel?.channelWidth.rawValue),
            rssi: normalizedMeasurement(interface.rssiValue()),
            noise: actualNetwork.flatMap { normalizedMeasurement($0.noiseMeasurement) },
            phyMode: displayPHY(interface.activePHYMode().rawValue),
            transmitRateMbps: transmitRate.isFinite && transmitRate > 0 ? transmitRate : nil,
            security: WiFiSecurityKind(coreWLANRawValue: interface.security().rawValue),
            countryCode: actualNetwork?.countryCode,
            interfaceName: interfaceName,
            ipv4Addresses: configuration.ipv4Addresses,
            ipv6Addresses: configuration.ipv6Addresses,
            router: configuration.router,
            dnsServers: configuration.dnsServers
        )
    }

    private func networkConfiguration(interface: String) -> WiFiServiceNetworkConfiguration {
        guard let store = SCDynamicStoreCreate(nil, "StatusTrio" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/.*" as CFString) as? [String] else {
            return .unavailable
        }
        var snapshot: [String: [String: Any]] = [:]
        for key in keys where key == "State:/Network/Global/IPv4" || key.hasPrefix("State:/Network/Service/") {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] {
                snapshot[key] = value
            }
        }
        return WiFiServiceNetworkConfiguration.resolve(interface: interface, snapshot: snapshot)
    }

    private func normalizedMeasurement(_ value: Int) -> Int? {
        value < 0 ? value : nil
    }

    private func bssid(_ lhs: String?, matches rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func displayBand(_ rawValue: Int?) -> String? {
        guard let rawValue else { return nil }
        return switch rawValue {
        case 1: "2.4 GHz"
        case 2: "5 GHz"
        case 3: "6 GHz"
        default: nil
        }
    }

    private func displayChannelWidth(_ rawValue: Int?) -> String? {
        guard let rawValue else { return nil }
        return switch rawValue {
        case 1: "20 MHz"
        case 2: "40 MHz"
        case 3: "80 MHz"
        case 4: "160 MHz"
        default: nil
        }
    }

    private func displayPHY(_ rawValue: Int) -> String? {
        return switch rawValue {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "802.11n"
        case 5: "802.11ac"
        case 6: "802.11ax"
        default: nil
        }
    }
}

@MainActor
final class WiFiNetworkController: ObservableObject {
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var details = WiFiConnectionDetails.unavailable
    @Published private(set) var state: WiFiListState = .idle
    /// The network the password sheet is asking about, if any.
    @Published private(set) var passwordPromptNetwork: WiFiNetwork?
    /// The network the last join attempt failed or timed out for, so the panel
    /// can offer the re-enter/forget healing path against the right identity.
    @Published private(set) var joinIssueNetwork: WiFiNetwork?
    /// Opt-in experiment: joining from the popover. Off means every row opens
    /// System Settings and none of the join entry points do anything.
    var allowsJoining = false

    private let worker: any WiFiNetworkScanning
    private let credentialWorker: WiFiCredentialWorker
    private let now: () -> Date
    /// A full scan sweeps every channel, so the automatic path may not run one
    /// more often than this. Explicit user actions bypass it.
    private let minimumScanInterval: TimeInterval
    private let periodicRefreshInterval: Duration
    private let periodicRefreshSleep: @Sendable (Duration) async throws -> Void
    private var scanGate = AsyncRequestGate()
    private var connectionGate = AsyncRequestGate()
    private var pendingNetwork: WiFiNetwork?
    private(set) var isActive = false
    /// When the last scan started, which is what the interval is measured from.
    private var lastScanStartedAt: Date?
    private var periodicRefreshTask: Task<Void, Never>?
    private var lastNameAccess: WiFiNameAccess = .notDetermined

    init(
        scanWorker: any WiFiNetworkScanning = CoreWLANNetworkWorker(),
        credentialStore: any WiFiCredentialStoring = KeychainWiFiPasswordStore(),
        now: @escaping () -> Date = Date.init,
        minimumScanInterval: TimeInterval = 120,
        periodicRefreshInterval: Duration = .seconds(60),
        periodicRefreshSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0, tolerance: $0 / 5)
        }
    ) {
        self.worker = scanWorker
        credentialWorker = WiFiCredentialWorker(store: credentialStore)
        self.now = now
        self.minimumScanInterval = minimumScanInterval
        self.periodicRefreshInterval = periodicRefreshInterval
        self.periodicRefreshSleep = periodicRefreshSleep
    }
    deinit {
        periodicRefreshTask?.cancel()
    }

    func activate(nameAccess: WiFiNameAccess) {
        guard !isActive else { refresh(nameAccess: nameAccess); return }
        lastNameAccess = nameAccess
        isActive = true
        if nameAccess == .authorized { schedulePeriodicRefresh() }
        refresh()
    }
    func deactivate() {
        guard isActive else { return }
        isActive = false
        _ = scanGate.advance()
        _ = connectionGate.advance()
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        pendingNetwork = nil
        passwordPromptNetwork = nil
        joinIssueNetwork = nil
        // A scan that is in flight now has a completion that the `isActive`
        // guard above will drop, so leaving the scan on `.scanning` would block
        // every later `refresh`/`refreshNow` through `startScan`'s
        // `!state.isScanning` guard. Clearing the floor timestamp as well makes
        // the next `activate` start a clean cadence instead of inheriting this
        // session's scan.
        if state.isScanning || state.isConnectionFlow {
            state = .idle
        }
        lastScanStartedAt = nil
    }

    /// The automatic path: the periodic loop and every Wi-Fi status yield come
    /// through here. Inside the interval the cached list is kept, because the
    /// list only changes when the radio changes, and that path calls
    /// `refreshNow(nameAccess:)`.
    func refresh(nameAccess: WiFiNameAccess? = nil) {
        let permissionChanged = nameAccess.map { $0 != lastNameAccess } ?? false
        if let nameAccess { lastNameAccess = nameAccess }
        if permissionChanged {
            _ = scanGate.advance()
            networks = []
            details = .unavailable
            state = .idle
            lastScanStartedAt = nil
            periodicRefreshTask?.cancel()
            periodicRefreshTask = nil
            if isActive, lastNameAccess == .authorized { schedulePeriodicRefresh() }
        }
        guard permissionChanged || hasScanElapsed else { return }
        startScan()
    }

    /// The explicit path: the refresh button and the radio toggle. A user asked
    /// for this, so it scans even inside the interval.
    func refreshNow(nameAccess: WiFiNameAccess? = nil) {
        if let nameAccess { lastNameAccess = nameAccess }
        startScan()
    }

    private var hasScanElapsed: Bool {
        guard let lastScanStartedAt else { return true }
        return now().timeIntervalSince(lastScanStartedAt) >= minimumScanInterval
    }

    private func startScan() {
        guard isActive, state.allowsRefresh else { return }

        let request = scanGate.advance()
        lastScanStartedAt = now()
        state = .scanning
        let completion: @Sendable (WiFiScanWorkerResult) -> Void = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.scanGate.accepts(request),
                      !self.state.isConnectionFlow else { return }
                self.receiveScanResult(result)
            }
        }
        if lastNameAccess == .authorized {
            worker.scan(completion: completion)
        } else {
            worker.readBasicDetails(completion: completion)
        }
    }
    func setPower(_ enabled: Bool) {
        guard isActive else { return }

        _ = scanGate.advance()
        _ = connectionGate.advance()
        pendingNetwork = nil
        passwordPromptNetwork = nil
        joinIssueNetwork = nil
        worker.setPower(enabled) { [weak self] changed in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                if changed {
                    self.state = .ready
                    self.refreshNow()
                } else {
                    self.state = .failed
                }
            }
        }
    }

    /// One-shot radio power change for a surface that is not the Wi-Fi list
    /// demand, such as the menu-bar right-click quick action. Unlike `setPower`
    /// it does not require `isActive`; when the list happens to be active it
    /// still refreshes the cached scan as the normal path does. The snapshot is
    /// refreshed by the regular monitor cadence afterward.
    func setPowerFromQuickAction(_ enabled: Bool, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        _ = scanGate.advance()
        worker.setPower(enabled) { [weak self] changed in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isActive {
                    if changed {
                        self.state = .ready
                        self.refreshNow()
                    } else {
                        self.state = .failed
                    }
                }
                completion(changed)
            }
        }
    }

    // MARK: - In-app joining (opt-in experiment)

    /// Entry point for a row tap when the experiment is on. Open networks join
    /// immediately; protected networks try the app-owned credential store
    /// first and fall back to the password sheet. The system keychain is never
    /// read, so no authorization prompt can appear here.
    func join(_ network: WiFiNetwork) {
        guard isActive, allowsJoining, !state.isConnectionFlow, !network.isConnected else { return }

        pendingNetwork = network
        passwordPromptNetwork = nil
        joinIssueNetwork = nil

        guard network.security.requiresPassword else {
            startAssociation(to: network, password: nil, suppliedPassword: nil, rememberPassword: false)
            return
        }

        let request = connectionGate.advance()
        credentialWorker.resolve(network.identity) { [weak self] lookup in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.connectionGate.accepts(request),
                      self.pendingNetwork?.identity == network.identity else { return }
                switch lookup {
                case let .credential(password):
                    self.startAssociation(to: network, password: password, suppliedPassword: nil, rememberPassword: false)
                case .noCredential, .readFailed:
                    // A broken or missing app-owned item is healed by asking
                    // once; the store is rewritten on the next success.
                    self.passwordPromptNetwork = network
                    self.state = .needsPassword
                }
            }
        }
    }

    /// The password sheet's submit action.
    func submitPassword(_ password: String, rememberPassword: Bool) {
        guard isActive, let network = pendingNetwork else { return }
        guard !password.isEmpty else { return }

        passwordPromptNetwork = nil
        joinIssueNetwork = nil
        startAssociation(
            to: network,
            password: password,
            suppliedPassword: password,
            rememberPassword: rememberPassword
        )
    }

    func cancelJoin() {
        guard state.isConnectionFlow || passwordPromptNetwork != nil else { return }
        _ = connectionGate.advance()
        passwordPromptNetwork = nil
        pendingNetwork = nil
        joinIssueNetwork = nil
        state = .ready
    }

    /// Healing path after a failed join: drop the stored credential for the
    /// network that failed and let the next tap ask again.
    func forgetIssueNetworkCredential() {
        guard let network = joinIssueNetwork else { return }
        credentialWorker.delete(network.identity)
        joinIssueNetwork = nil
        pendingNetwork = nil
        state = .ready
    }

    /// Dismisses the failure state and keeps the stored credential, so the
    /// next tap retries with it.
    func dismissJoinIssue() {
        joinIssueNetwork = nil
        pendingNetwork = nil
        state = .ready
    }

    /// Healing path after a failed join: ask for the password again. The
    /// stored credential is left in place until a new one is saved.
    func reenterPasswordForIssueNetwork() {
        guard let network = joinIssueNetwork else { return }
        pendingNetwork = network
        joinIssueNetwork = nil
        passwordPromptNetwork = network
        state = .needsPassword
    }

    /// Turning the experiment switch off offers to delete every stored
    /// password; this performs that deletion.
    func deleteAllCredentials() {
        credentialWorker.deleteAll()
    }

    private func startAssociation(
        to network: WiFiNetwork,
        password: String?,
        suppliedPassword: String?,
        rememberPassword: Bool
    ) {
        let request = connectionGate.advance()
        passwordPromptNetwork = nil
        state = .connecting(network.identity)

        worker.associate(to: network, password: password) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.connectionGate.accepts(request) else { return }
                self.receiveAssociationResult(
                    result,
                    for: network,
                    suppliedPassword: suppliedPassword,
                    rememberPassword: rememberPassword
                )
            }
        }
    }

    private func receiveAssociationResult(
        _ result: WiFiAssociationWorkerResult,
        for network: WiFiNetwork,
        suppliedPassword: String?,
        rememberPassword: Bool
    ) {
        switch result {
        case let .success(connectionDetails):
            details = connectionDetails
            state = .ready
            pendingNetwork = nil
            joinIssueNetwork = nil
            if rememberPassword, let suppliedPassword {
                // A failed save is not retried loudly: the network is already
                // joined, and the next tap simply asks again.
                credentialWorker.save(suppliedPassword, for: network.identity) { _ in }
            }
            refreshNow()
        case .networkUnavailable:
            joinIssueNetwork = network
            state = .networkUnavailable
        case .timedOut:
            joinIssueNetwork = network
            state = .connectionTimedOut
        case .failed:
            joinIssueNetwork = network
            state = .connectionFailed
        }
    }

    private func receiveScanResult(_ result: WiFiScanWorkerResult) {
        switch result {
        case let .success(payload):
            details = payload.details
            networks = payload.networks
            if payload.networks.isEmpty,
               lastNameAccess == .denied || lastNameAccess == .restricted {
                state = .permissionDenied
            } else {
                state = .ready
            }
        case .poweredOff:
            details = .unavailable
            networks = []
            state = .poweredOff
        case .noInterface:
            details = .unavailable
            networks = []
            state = .noInterface
        case .failed:
            state = lastNameAccess == .denied || lastNameAccess == .restricted
                ? .permissionDenied
                : .failed
        }
    }

    private func schedulePeriodicRefresh() {
        periodicRefreshTask?.cancel()
        let interval = periodicRefreshInterval
        let sleep = periodicRefreshSleep
        periodicRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard let self, self.isActive else { return }
                self.refresh()
            }
        }
    }

}
