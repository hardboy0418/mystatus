import SwiftUI

struct WiFiNetworkListView: View {
    @EnvironmentObject private var localization: Localization
    @Environment(\.colorScheme) private var colorScheme
    let state: WiFiPanelState
    let onBack: () -> Void
    let onRequestNameAccess: () -> Void
    let onOpenWiFiSettings: () -> Void
    let onOpenLocationSettings: () -> Void
    let onSetPower: (Bool) -> Void
    /// Mirrors the "Confirm Before Turning Off Wi-Fi" setting (#305) so the
    /// detail page and the summary row behave the same. Defaults to false for
    /// previews and fixtures that do not exercise the confirmation.
    var wifiPowerRequiresConfirmation: Bool = false
    let onRefresh: () -> Void
    let onOpenSharingSettings: () -> Void
    let onCopyValue: (String) -> Void
    let showsDetails: Bool
    let showsMore: Bool
    let onSetShowsDetails: (Bool) -> Void
    let onSetShowsMore: (Bool) -> Void
    /// In-app joining (opt-in experiment). Defaults keep previews and fixtures
    /// on the System-Settings-only path.
    var onJoin: (WiFiNetworkIdentity) -> Void = { _ in }
    var onSubmitPassword: (String, Bool) -> Void = { _, _ in }
    var onCancelJoin: () -> Void = {}
    var onReenterPassword: () -> Void = {}
    var onForgetIssueCredential: () -> Void = {}

    /// The panel owns one outer scroll surface (#237); this page must not add a
    /// second one on top of it.
    @Environment(\.statusPanelManagesScrolling) private var statusPanelManagesScrolling

    @State private var confirmingPowerOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Toggle(
                localization.string(.wifiPower),
                isOn: Binding(
                    get: { state.powerIsOn },
                    set: { requested in
                        // Turning off while associated asks first, unless the
                        // user turned the confirmation setting off (#305).
                        if !requested && wifiPowerRequiresConfirmation {
                            confirmingPowerOff = true
                        } else {
                            onSetPower(requested)
                        }
                    }
                )
            )
            .disabled(!state.canSetPower)
            .alert(
                localization.string(.wifiPowerOffConfirmTitle),
                isPresented: $confirmingPowerOff
            ) {
                Button(localization.string(.wifiPowerOffConfirmAction), role: .destructive) {
                    onSetPower(false)
                }
                Button(localization.string(.commonCancel), role: .cancel) {}
            } message: {
                Text(localization.string(.wifiPowerOffConfirmMessage))
            }

            if statusPanelManagesScrolling {
                networkSections
            } else {
                ScrollView {
                    networkSections
                }
                .frame(maxHeight: 330)
            }

            Divider()
            Text(localization.string(.wifiActionSwitchingHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(localization.string(.wifiActionOpenSettings), action: onOpenWiFiSettings)
                .buttonStyle(.plain)
                .accessibilityLabel(localization.string(.wifiActionOpenSettings))
            // Internet Sharing can share from the Wi-Fi connection too, so this
            // is offered here and not only on the wired details page.
            Button(localization.string(.networkActionShareInternet), action: onOpenSharingSettings)
                .buttonStyle(.plain)
                .help(localization.string(.networkActionShareInternetHelp))
        }
        .sheet(item: passwordPromptBinding) { network in
            WiFiPasswordSheet(
                network: network,
                onJoin: { password, remember in
                    onSubmitPassword(password, remember)
                },
                onCancel: onCancelJoin
            )
            .environmentObject(localization)
        }
    }

    /// Drives the password sheet from the panel state. The sheet cannot set the
    /// state itself, so dismissal routes through `onCancelJoin`.
    private var passwordPromptBinding: Binding<WiFiNetwork?> {
        Binding(
            get: { state.passwordPromptNetwork },
            set: { newValue in
                if newValue == nil { onCancelJoin() }
            }
        )
    }

    private var networkSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            personalHotspotSection
            knownNetworksSection
            otherNetworksSection
            stateMessage(
                hasVisibleNetworks: !state.personalHotspotRows.isEmpty
                    || !state.knownRows.isEmpty
                    || !state.otherRows.isEmpty
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            NavigationBackRow(
                accessibilityLabel: localization.string(.commonBack),
                title: localization.string(.wifiTitle),
                action: onBack
            )
            Button(action: onRefresh) {
                PanelActionGlyph(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(!state.canRefresh)
            .accessibilityLabel(localization.string(.wifiRefresh))
        }
    }

    @ViewBuilder
    private var personalHotspotSection: some View {
        if !state.personalHotspotRows.isEmpty {
            sectionTitle(localization.string(.wifiPersonalHotspot))
            ForEach(state.personalHotspotRows, id: \.key) { row in
                networkRow(row)
            }
            if state.personalHotspotRows.contains(where: \.selected), state.showsConnectionDetails {
                detailsToggle
            }
        }
    }

    @ViewBuilder
    private var knownNetworksSection: some View {
        if !state.knownRows.isEmpty || state.showsConnectionDetails {
            sectionTitle(localization.string(.wifiKnownNetworks))
            ForEach(state.knownRows, id: \.key) { row in
                networkRow(row)
            }
            if state.showsConnectionDetails {
                detailsToggle
            }
        }
    }

    @ViewBuilder
    private var otherNetworksSection: some View {
        if !state.otherRows.isEmpty {
            sectionTitle(localization.string(.wifiOtherNetworks))
            ForEach(state.otherRows, id: \.key) { row in
                networkRow(row)
            }
        }
    }

    @ViewBuilder
    private var detailsToggle: some View {
        WiFiDetailsToggleRow(isExpanded: showsDetailsBinding)

        if showsDetails {
            WiFiDetailsView(
                state: state,
                showsMore: showsMoreBinding,
                onCopyValue: onCopyValue
            )
        }
    }

    private var showsDetailsBinding: Binding<Bool> {
        Binding(
            get: { showsDetails },
            set: { value in onSetShowsDetails(value) }
        )
    }

    private var showsMoreBinding: Binding<Bool> {
        Binding(
            get: { showsMore },
            set: { value in onSetShowsMore(value) }
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var stateMessage: some View {
        EmptyView()
    }

    @ViewBuilder
    private func stateMessage(hasVisibleNetworks _: Bool) -> some View {
        if let message = state.message {
            switch state.messageIntent {
            case .requestWiFiNameAccess:
                WiFiPermissionActionButton(
                    icon: "location.fill",
                    title: message,
                    action: onRequestNameAccess
                )
            case .locationSettings:
                WiFiPermissionActionButton(
                    icon: "location.fill",
                    title: message,
                    action: onOpenLocationSettings
                )
            case .joinIssue:
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    HStack(spacing: 12) {
                        Button(localization.string(.wifiReenterPassword), action: onReenterPassword)
                            .buttonStyle(.plain)
                            .font(.caption)
                        Button(localization.string(.wifiForgetNetwork), action: onForgetIssueCredential)
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                HStack(spacing: 8) {
                    if state.isScanning || state.isJoining { ProgressView().controlSize(.small) }
                    Text(message)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var connectedMarkerColor: Color {
        WiFiConnectedMarkerPalette.resolved(dark: colorScheme == .dark).color
    }

    private func networkRow(_ row: PanelWiFiNetworkRow) -> some View {
        Button {
            switch row.action {
            case .openSettings:
                onOpenWiFiSettings()
            case .join:
                onJoin(row.key)
            case .none:
                break
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if row.selected {
                    Image(systemName: "checkmark")
                        .frame(width: 16, height: 16, alignment: .center)
                        .foregroundStyle(connectedMarkerColor)
                        .opacity(row.opensSettings ? 1 : 0)
                        // The button's accessibility label already says
                        // "Connected"; the marker is decoration.
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "wifi")
                        .frame(width: 16, height: 16, alignment: .center)
                        .foregroundStyle(.secondary)
                }
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let marker = row.securityMarker {
                    Image(systemName: marker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16, alignment: .center)
                        .accessibilityHidden(true)
                }
                if let systemImage = row.signalSystemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16, alignment: .center)
                        .accessibilityHidden(true)
                } else {
                    PanelSymbolView(source: row.signalSymbol, size: 14, weight: .regular)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16, alignment: .center)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.action == .none || state.isJoining)
        .overlay(alignment: .leading) {
            if row.selected && !row.opensSettings {
                // A disabled button dims its whole label, but connection state
                // is not a control — draw the marker again outside that dimming.
                // Keep this frame and leading alignment in sync with the marker
                // inside the label above.
                Image(systemName: "checkmark")
                    .frame(width: 16, height: 16, alignment: .center)
                    .foregroundStyle(connectedMarkerColor)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(row.accessibilityLabel)
    }
}

private struct WiFiDetailsView: View {
    let state: WiFiPanelState
    @Binding var showsMore: Bool
    let onCopyValue: (String) -> Void

    var body: some View {
        VStack(spacing: 5) {
            PanelDetailRowsView(
                detailRows: state.visibleDetailRows(expanded: showsMore),
                onCopyValue: onCopyValue
            )
            Button(showsMore ? state.showLessTitle : state.showMoreTitle) {
                showsMore.toggle()
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 26)
        .font(.caption)
    }
}

/// The password prompt for the in-app joining experiment. The password goes to
/// CoreWLAN and, only on success and when the box stays ticked, to the app's
/// own keychain item — never to defaults or the system AirPort items.
private struct WiFiPasswordSheet: View {
    @EnvironmentObject private var localization: Localization
    let network: WiFiNetwork
    let onJoin: (String, Bool) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var rememberPassword = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.string(.wifiJoinNetwork))
                .font(.headline)
            Text(network.ssid.isEmpty ? localization.string(.wifiHiddenNetwork) : network.ssid)
                .lineLimit(1)
            SecureField(localization.string(.wifiPassword), text: $password)
            Toggle(localization.string(.wifiRememberPassword), isOn: $rememberPassword)
            Text(localization.string(.wifiPasswordKeychainNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(localization.string(.commonCancel)) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localization.string(.wifiJoin)) {
                    onJoin(password, rememberPassword)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
