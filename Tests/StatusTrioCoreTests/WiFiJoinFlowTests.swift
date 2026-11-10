import Foundation
import XCTest
@testable import StatusTrioCore

/// The in-app joining experiment: the opt-in flag, the credential-first flow,
/// the password-sheet fallback, and the failure healing paths. Everything runs
/// against fakes — no CoreWLAN, no keychain — so the flow is pinned by the
/// controller's published state.
@MainActor
final class WiFiJoinFlowTests: XCTestCase {
    private func makeController(
        scanner: FakeJoinScanner,
        store: FakeWiFiCredentialStore
    ) -> WiFiNetworkController {
        WiFiNetworkController(
            scanWorker: scanner,
            credentialStore: store,
            minimumScanInterval: 120,
            periodicRefreshSleep: { try await Task.sleep(for: $0) }
        )
    }

    private func makeNetwork(
        _ ssid: String,
        security: WiFiSecurityKind,
        connected: Bool = false
    ) -> WiFiNetwork {
        WiFiNetwork(
            identity: WiFiNetworkIdentity(ssid: ssid, security: security),
            candidates: [
                WiFiNetworkCandidate(ssid: ssid, bssid: "aa:bb:cc:dd:ee:ff", rssi: -50, channel: 6, security: security)
            ],
            connectedBSSID: connected ? "aa:bb:cc:dd:ee:ff" : nil,
            isKnown: false
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the Wi-Fi join flow")
    }

    func testJoinIsIgnoredWhileTheExperimentIsOff() async {
        let scanner = FakeJoinScanner()
        let store = FakeWiFiCredentialStore()
        let controller = makeController(scanner: scanner, store: store)
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(makeNetwork("Cafe", security: .wpa2Personal))
        await Task.yield()

        XCTAssertEqual(scanner.associateCount, 0)
        XCTAssertNil(controller.passwordPromptNetwork)
        controller.deactivate()
    }

    func testJoinUsesTheStoredCredentialWithoutAPrompt() async {
        let scanner = FakeJoinScanner()
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("Home", security: .wpa2Personal)
        store.credentials[network.identity] = "stored-secret"
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { controller.state == .ready && scanner.associateCount == 1 }

        XCTAssertEqual(scanner.lastPassword, "stored-secret")
        XCTAssertNil(controller.passwordPromptNetwork)
        // A stored credential is reused, not rewritten.
        XCTAssertEqual(store.saveCount, 0)
        controller.deactivate()
    }

    func testJoinWithoutCredentialAsksForPasswordThenStoresOnSuccess() async {
        let scanner = FakeJoinScanner()
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("Cafe", security: .wpa2Personal)
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { controller.state == .needsPassword }
        XCTAssertEqual(controller.passwordPromptNetwork?.identity, network.identity)
        XCTAssertEqual(scanner.associateCount, 0)

        controller.submitPassword("typed-secret", rememberPassword: true)
        await waitUntil { controller.state == .ready && scanner.associateCount == 1 }

        XCTAssertEqual(scanner.lastPassword, "typed-secret")
        // The save rides the credential worker's queue, after the association
        // result lands.
        await waitUntil { store.credentials[network.identity] != nil }
        XCTAssertEqual(store.credentials[network.identity], "typed-secret")
        controller.deactivate()
    }

    func testJoinWithRememberOffDoesNotStoreThePassword() async {
        let scanner = FakeJoinScanner()
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("Cafe", security: .wpa2Personal)
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { controller.state == .needsPassword }
        controller.submitPassword("typed-secret", rememberPassword: false)
        await waitUntil { controller.state == .ready && scanner.associateCount == 1 }

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(store.credentials[network.identity])
        controller.deactivate()
    }

    func testOpenNetworkJoinsWithoutPasswordOrStore() async {
        let scanner = FakeJoinScanner()
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("OpenNet", security: .open)
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { scanner.associateCount == 1 }
        await waitUntil { controller.state == .ready }

        XCTAssertNil(scanner.lastPassword)
        XCTAssertEqual(store.resolveCount, 0)
        XCTAssertNil(controller.passwordPromptNetwork)
        controller.deactivate()
    }

    func testFailedJoinOffersTheHealingPathAndForgettingDeletesTheCredential() async {
        let scanner = FakeJoinScanner()
        scanner.associationResult = .failed
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("Home", security: .wpa2Personal)
        store.credentials[network.identity] = "stale-secret"
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { controller.state == .connectionFailed }

        XCTAssertEqual(controller.joinIssueNetwork?.identity, network.identity)
        // A failure is not a scan in flight: the refresh affordance is back.
        XCTAssertTrue(controller.state.allowsRefresh)

        controller.forgetIssueNetworkCredential()
        await waitUntil { store.credentials[network.identity] == nil }
        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.joinIssueNetwork)
        controller.deactivate()
    }

    func testReenterPasswordAfterFailurePromptsAgain() async {
        let scanner = FakeJoinScanner()
        scanner.associationResult = .timedOut
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("Home", security: .wpa2Personal)
        store.credentials[network.identity] = "stale-secret"
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { controller.state == .connectionTimedOut }

        controller.reenterPasswordForIssueNetwork()
        await waitUntil { controller.state == .needsPassword }
        XCTAssertEqual(controller.passwordPromptNetwork?.identity, network.identity)
        // The stale credential is only replaced by a successful new join.
        XCTAssertEqual(store.credentials[network.identity], "stale-secret")
        controller.deactivate()
    }

    func testCancelDuringPasswordEntryReturnsToReady() async {
        let scanner = FakeJoinScanner()
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("Cafe", security: .wpa2Personal)
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { controller.state == .needsPassword }
        controller.cancelJoin()

        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.passwordPromptNetwork)
        XCTAssertEqual(scanner.associateCount, 0)
        controller.deactivate()
    }

    func testDeactivateDropsAnInFlightJoin() async {
        let scanner = FakeJoinScanner()
        scanner.holdsAssociation = true
        let store = FakeWiFiCredentialStore()
        let network = makeNetwork("Cafe", security: .open)
        let controller = makeController(scanner: scanner, store: store)
        controller.allowsJoining = true
        controller.activate(nameAccess: .authorized)
        await waitUntil { controller.state == .ready }

        controller.join(network)
        await waitUntil { controller.state.isConnectionFlow }
        controller.deactivate()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isActive)
    }
}

/// The scan side answers instantly with one network; the association side is
/// configurable and can hold its completion to simulate an in-flight join.
private final class FakeJoinScanner: WiFiNetworkScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var associates = 0
    private var passwords: [String?] = []
    private var heldAssociation: (@Sendable (WiFiAssociationWorkerResult) -> Void)?

    var holdsAssociation = false
    var associationResult: WiFiAssociationWorkerResult = .success(.unavailable)
    var result: WiFiScanWorkerResult = .success(
        WiFiScanPayload(
            networks: [
                WiFiNetwork(
                    identity: WiFiNetworkIdentity(ssid: "Studio", security: .open),
                    candidates: [
                        WiFiNetworkCandidate(ssid: "Studio", bssid: nil, rssi: -50, channel: 6, security: .open)
                    ],
                    connectedBSSID: nil,
                    isKnown: true
                )
            ],
            details: .unavailable
        )
    )

    var associateCount: Int { lock.withLock { associates } }
    var lastPassword: String? { lock.withLock { passwords.last ?? nil } }

    func scan(completion: @escaping @Sendable (WiFiScanWorkerResult) -> Void) {
        completion(lock.withLock { result })
    }

    func setPower(_: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        completion(true)
    }

    func associate(
        to _: WiFiNetwork,
        password: String?,
        completion: @escaping @Sendable (WiFiAssociationWorkerResult) -> Void
    ) {
        lock.withLock {
            associates += 1
            passwords.append(password)
        }
        if holdsAssociation {
            lock.withLock { heldAssociation = completion }
        } else {
            completion(lock.withLock { associationResult })
        }
    }
}

/// In-memory credential store: same contract as the keychain store, no
/// Security framework involved.
private final class FakeWiFiCredentialStore: WiFiCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WiFiNetworkIdentity: String] = [:]
    private var resolves = 0
    private var saves = 0

    var credentials: [WiFiNetworkIdentity: String] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var resolveCount: Int { lock.withLock { resolves } }
    var saveCount: Int { lock.withLock { saves } }

    func resolveCredential(for identity: WiFiNetworkIdentity) -> WiFiCredentialLookup {
        lock.withLock {
            resolves += 1
            return storage[identity].map { .credential($0) } ?? .noCredential
        }
    }

    func save(_ password: String, for identity: WiFiNetworkIdentity) -> Bool {
        lock.withLock {
            saves += 1
            storage[identity] = password
        }
        return true
    }

    func deleteCredential(for identity: WiFiNetworkIdentity) {
        lock.withLock { storage[identity] = nil }
    }

    func deleteAllCredentials() {
        lock.withLock { storage.removeAll() }
    }
}
