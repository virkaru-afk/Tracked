import SwiftUI

/// Storage, calibration and retention management.
public struct SettingsView: View {

    @EnvironmentObject private var state: AppState
    @State private var videoBytes: Int64 = 0
    @State private var expiringSoon: [StoredSession] = []
    @State private var storedIntrinsics: [CameraIntrinsics] = []
    @State private var supportedModes: [CaptureRequirements.HardwareMode] = []
    @State private var showingPruneConfirmation = false

    public init() {}

    public var body: some View {
        List {
            recordingModeSection
            storageSection
            retentionSection
            calibrationSection
            aboutSection
        }
        .navigationTitle("Settings")
        .task { await refresh() }
        .confirmationDialog("Remove expired footage?",
                            isPresented: $showingPruneConfirmation,
                            titleVisibility: .visible) {
            Button("Remove footage", role: .destructive) {
                Task {
                    _ = try? await state.sessionStore?.pruneExpiredVideos()
                    await refresh()
                    await state.refreshSessions()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Footage past its three-day window will be deleted. Every "
                 + "measurement is kept — only the video goes.")
        }
    }

    // MARK: Sections

    private var storageSection: some View {
        Section {
            LabeledContent("Video on device", value: formatted(bytes: videoBytes))
            LabeledContent("Trials recorded", value: "\(state.sessions.count)")
            LabeledContent("With footage",
                           value: "\(state.sessions.filter { $0.retention.hasVideo }.count)")
            Button("Remove expired footage now") {
                showingPruneConfirmation = true
            }
            .disabled(expiringSoon.isEmpty)
        } header: {
            Text("Storage")
        } footer: {
            Text("Analysis is a few kilobytes per trial and is kept permanently. "
                 + "Footage at 240 fps runs to several hundred megabytes per jump, so "
                 + "it is dropped after three days unless you pin it.")
        }
    }

    @ViewBuilder
    private var retentionSection: some View {
        if !expiringSoon.isEmpty {
            Section {
                ForEach(expiringSoon) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.athleteName) · trial \(session.trialNumber)")
                                .font(.subheadline)
                            if let expiry = session.retention.expiryDate {
                                let days = RetentionPolicy.daysRemaining(until: expiry)
                                Text(days == 0 ? "Footage goes today"
                                               : "Footage goes in \(days) day\(days == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Keep") {
                            Task {
                                try? await state.sessionStore?.keepVideo(id: session.id)
                                await refresh()
                                await state.refreshSessions()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Footage expiring soon")
            }
        }
    }

    private var calibrationSection: some View {
        Section {
            ForEach(storedIntrinsics, id: \.configurationFingerprint) { intrinsics in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(intrinsics.configurationFingerprint)
                            .font(.caption.monospaced())
                        Spacer()
                        if intrinsics.configurationFingerprint
                            == state.captureConfiguration?.fingerprint {
                            Text("in use")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(String(format: "%.0f px focal · %.2f px fit · %.0f° field of view",
                                intrinsics.focalLengthX,
                                intrinsics.calibrationRMSE,
                                intrinsics.horizontalFieldOfView))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if storedIntrinsics.isEmpty {
                Text("No lens calibrations stored yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Lens calibrations")
        } footer: {
            Text("One per capture mode. High-frame-rate modes crop the sensor, so a "
                 + "calibration measured in one mode is not valid in another.")
        }
    }

    /// Recording mode.
    ///
    /// Automatic picks the highest-preference mode this specific device
    /// supports — 1080p240 on anything that offers it — and is the right
    /// choice for almost everyone. The manual options exist for the coach
    /// shooting in genuinely poor light who would rather trade contact-timing
    /// precision for a mode less likely to drop frames: 1080p120 halves the
    /// per-frame exposure demand at a given shutter speed target compared to
    /// 240 fps, which matters when the sensor is already straining.
    private var recordingModeSection: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { state.preferredCaptureMode },
                set: { newMode in
                    Task { await state.setPreferredCaptureMode(newMode) }
                }
            )) {
                Text("Automatic — best available").tag(
                    Optional<CaptureRequirements.HardwareMode>.none)
                ForEach(supportedModes, id: \.fingerprint) { mode in
                    modeLabel(mode).tag(Optional(mode))
                }
            }
            .pickerStyle(.inline)

            if supportedModes.isEmpty {
                Label("Checking what this camera supports…",
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let active = state.captureController.selectedMode {
                LabeledContent("Currently active") {
                    Text("\(active.label) · \(active.width)×\(active.height)")
                        .font(.caption.monospacedDigit())
                }
            }
        } header: {
            Text("Recording quality")
        } footer: {
            Text("Changing this needs a fresh lens calibration for the new mode "
                 + "before recording, and starts a new comparable history — a "
                 + "1080p240 session and a 1080p120 session are different rulers "
                 + "and are never compared against each other.")
        }
    }

    private func modeLabel(_ mode: CaptureRequirements.HardwareMode)
        -> some View {
        HStack {
            Text(mode.label)
            Spacer()
            Text(mode.frameRate >= 240 ? "Best timing" : "Best low light")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Analysis pipeline", value: AnalysisPipeline.version)
            LabeledContent("Analysis grid",
                           value: "\(Int(ProcessingTimebase.safeDefaultRate))–"
                                + "\(Int(ProcessingTimebase.maximumUsefulRate)) Hz")
            LabeledContent("Device", value: CaptureConfiguration.currentDeviceModel)
            NavigationLink("Measurement accuracy") { AccuracyExplainerView() }
        } header: {
            Text("About")
        } footer: {
            Text("The analysis grid is set per recording from its own measured "
                 + "frame rate — never above what the camera delivered, never below "
                 + "120 Hz. Sessions analysed under different pipeline versions are "
                 + "not directly comparable. The version changes only when a filter "
                 + "or threshold that alters the numbers changes.")
        }
    }

    // MARK: Data

    private func refresh() async {
        supportedModes = state.supportedCaptureModes
        guard let store = state.sessionStore else { return }
        videoBytes = await store.videoBytesOnDisk()
        expiringSoon = (try? await store.videosExpiringSoon()) ?? []
        storedIntrinsics = await state.intrinsicsStore?.loadAll() ?? []
    }

    private func formatted(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Plain-language statement of what the numbers can and cannot do.
///
/// Present because the honest answer is more useful than a flattering one: a
/// coach who believes a 4 mm change in hop distance is real will chase noise,
/// and the app's whole design is built to stop that.
struct AccuracyExplainerView: View {

    var body: some View {
        List {
            ForEach([MetricCatalog.Tier.precise, .timing, .indicative], id: \.rawValue) { tier in
                Section(tierTitle(tier)) {
                    Text(tier.explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(MetricCatalog.all.filter { $0.tier == tier }) { definition in
                        HStack {
                            Text(definition.displayName)
                                .font(.caption)
                            Spacer()
                            if let threshold = MetricCatalog
                                .meaningfulChangeThreshold(for: definition.name) {
                                Text(MetricCatalog.formatChange(threshold,
                                                                unit: definition.unit)
                                        .replacingOccurrences(of: "+", with: ""))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("What is not measured") {
                Text("The jump phase has no distance. It lands in the pit, where the "
                     + "foot is hidden by the athlete's body and the sand, and where "
                     + "the landing is a slide rather than a plant — so there is no "
                     + "still contact to measure from. Phase shares are of hop plus "
                     + "step.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sideways motion — arm swing, trunk drift — cannot be recovered "
                     + "from one camera. It affects joint angles by roughly 10%.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Where the accuracy comes from") {
                Text("Absolute accuracy is limited by how precisely the board corners "
                     + "were tapped — about 10 mm of camera distance per 2 px of tap "
                     + "error. Session-to-session accuracy is much better, because "
                     + "reusing one stored profile makes that error a fixed offset "
                     + "that cancels out of any comparison.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Confirming the detected events by hand takes timing from about "
                     + "±15 ms to ±7 ms. It is the largest single improvement "
                     + "available.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Measurement accuracy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tierTitle(_ tier: MetricCatalog.Tier) -> String {
        switch tier {
        case .precise:    return "Distances — \(tier.label)"
        case .timing:     return "Timing — \(tier.label)"
        case .indicative: return "Technique — \(tier.label)"
        }
    }
}
