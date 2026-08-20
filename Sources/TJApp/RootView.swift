import SwiftUI

/// Home screen.
///
/// Presented as an ordered checklist rather than a menu of equals, because
/// the steps genuinely depend on each other: lens calibration scales
/// everything, tripod calibration depends on the lens, and analysis depends
/// on both. Showing them as peers would invite users to start in the middle
/// and get numbers that look plausible and are wrong.
public struct RootView: View {

    @StateObject private var state = AppState()
    @State private var showingIntrinsics = false
    @State private var showingTripodCalibration = false
    @State private var showingCapture = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if let error = state.startupError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let notice = state.retentionNotice {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "externaldrive.badge.minus")
                                .foregroundStyle(.secondary)
                            Text(notice)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("OK") { state.dismissRetentionNotice() }
                                .font(.caption)
                        }
                    }
                }

                Section {
                    statusRow
                } header: {
                    Text("Status")
                }

                Section {
                    checkerboardRow
                    intrinsicsRow
                    tripodRow
                    recordRow
                } header: {
                    Text("Setup and capture")
                } footer: {
                    Text("Each step depends on the one above it. The printed target is "
                         + "made once; lens calibration is measured once per phone and "
                         + "capture mode; the tripod profile is created once per runway "
                         + "setup and reused every session.")
                }

                if !state.profiles.isEmpty {
                    Section("Tripod profiles") {
                        ForEach(state.profiles) { profile in
                            profileRow(profile)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        if let store = state.sessionStore {
                            SessionHistoryView(store: store,
                                               reanalyser: state.analysisRunner)
                        }
                    } label: {
                        Label("All trials", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(state.sessionStore == nil)

                    NavigationLink {
                        HardwareCheckView().environmentObject(state)
                    } label: {
                        Label("Hardware check", systemImage: "stethoscope")
                    }

                    NavigationLink {
                        SettingsView().environmentObject(state)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                if !state.sessions.isEmpty {
                    Section("Recent trials") {
                        ForEach(state.sessions.prefix(5)) { session in
                            NavigationLink {
                                if let store = state.sessionStore {
                                    ResultsView(session: session,
                                                store: store,
                                                reanalyser: state.analysisRunner)
                                }
                            } label: {
                                recentRow(session)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Triple Jump")
            .task { await state.bootstrap() }
            .sheet(isPresented: $showingIntrinsics) {
                IntrinsicCalibrationView(store: state.intrinsicsStore,
                                        captureController: state.captureController,
                                        preferredMode: state.preferredCaptureMode) { intrinsics in
                    state.setIntrinsics(intrinsics)
                }
            }
            .sheet(isPresented: $showingTripodCalibration) {
                tripodCalibrationSheet
            }
            .fullScreenCover(isPresented: $showingCapture) {
                CaptureView().environmentObject(state)
            }
        }
        .environmentObject(state)
    }

    // MARK: - Rows

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: state.readiness == .ready
                  ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(state.readiness == .ready ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.readiness.title).font(.subheadline.weight(.semibold))
                Text(state.readiness.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// Step zero: the printed target.
    ///
    /// Shown as a step rather than buried in settings because it is the one
    /// prerequisite the app cannot supply for the user, and because a user
    /// who reaches lens calibration without a board has to stop and find a
    /// printer — which in practice means they stop.
    private var checkerboardRow: some View {
        NavigationLink {
            CheckerboardSetupView()
        } label: {
            HStack {
                stepIcon(number: 1, done: state.intrinsics != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Print the calibration target").foregroundStyle(.primary)
                    Text(state.intrinsics != nil
                         ? "Already used for this capture mode"
                         : "A checkerboard on rigid, matte board")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var intrinsicsRow: some View {
        Button {
            showingIntrinsics = true
        } label: {
            HStack {
                stepIcon(number: 2, done: state.intrinsics != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calibrate lens").foregroundStyle(.primary)
                    if let intrinsics = state.intrinsics {
                        Text(String(format: "Done — %.0f px focal, %.2f px fit error",
                                    intrinsics.focalLengthX,
                                    intrinsics.calibrationRMSE))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let configuration = state.captureConfiguration {
                        Text("Needed for \(configuration.fingerprint)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(state.intrinsicsStore == nil)
    }

    private var tripodRow: some View {
        Button {
            showingTripodCalibration = true
        } label: {
            HStack {
                stepIcon(number: 3, done: state.selectedProfile != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calibrate tripod position").foregroundStyle(.primary)
                    if let profile = state.selectedProfile {
                        Text(String(format: "%@ — %.2f m from board",
                                    profile.name, profile.pose.distance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap the board corners and reference pipe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(state.intrinsics == nil)
    }

    private var recordRow: some View {
        Button {
            showingCapture = true
        } label: {
            HStack {
                stepIcon(number: 4, done: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record a jump")
                        .foregroundStyle(state.canRecord ? .primary : .secondary)
                    Text(state.canRecord
                         ? "Capture and analyse"
                         : "Complete the steps above first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.canRecord {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(!state.canRecord)
        .opacity(state.canRecord ? 1 : 0.55)
    }

    private func profileRow(_ profile: CalibrationProfile) -> some View {
        Button {
            state.selectedProfileID = profile.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).foregroundStyle(.primary)
                    Text("\(profile.sessionCount) sessions · "
                         + String(format: "%.2f m · %.1f px fit",
                                  profile.pose.distance, profile.reprojectionRMSE))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if profile.id == state.selectedProfileID {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await state.deleteProfile(id: profile.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func recentRow(_ session: StoredSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.athleteName).font(.subheadline)
                    if session.eventsConfirmed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let hop = session.record.metricValues["Hop distance"] {
                Text(Imperial.feetInches(hop))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepIcon(number: Int, done: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 26, height: 26)
            if done {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tripod calibration

    @ViewBuilder
    private var tripodCalibrationSheet: some View {
        if let intrinsics = state.intrinsics {
            TripodCalibrationContainer(intrinsics: intrinsics,
                                       controller: state.captureController) { profile in
                Task { await state.addProfile(profile) }
                showingTripodCalibration = false
            }
        } else {
            VStack(spacing: 12) {
                Text("Calibrate the lens first")
                    .font(.headline)
                Text("Tripod calibration solves for the camera's distance from the "
                     + "board, and that solve needs the lens focal length. Without "
                     + "it the recovered distance would be scaled by an unknown "
                     + "factor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        }
    }
}

/// Runs the shared capture session for the duration of tripod calibration.
///
/// Uses the app's single `CaptureController` rather than building its own. A
/// second session would make it possible to calibrate the tripod in one
/// capture format and record in another — precisely the mismatch the
/// fingerprint machinery exists to prevent, and invisible while it happened,
/// because both would look like a perfectly good camera preview.
public struct TripodCalibrationContainer: View {

    public let intrinsics: CameraIntrinsics
    public let controller: CaptureController
    public let onComplete: (CalibrationProfile) -> Void

    public init(intrinsics: CameraIntrinsics,
                controller: CaptureController,
                onComplete: @escaping (CalibrationProfile) -> Void) {
        self.intrinsics = intrinsics
        self.controller = controller
        self.onComplete = onComplete
    }

    public var body: some View {
        TripodCalibrationView(intrinsics: intrinsics,
                              imageSize: CGSize(width: intrinsics.imageWidth,
                                                height: intrinsics.imageHeight),
                              session: controller.session,
                              onComplete: onComplete)
            .task {
                // This screen shares the session configured at startup, which
                // is configured for recording — locked focus and a 1/500 s
                // exposure. Fine for a jump, unusable for tapping board
                // corners: the preview cannot focus and is far too dark
                // indoors. Opened here without re-resolving the format, which
                // has to stay exactly what the intrinsics were measured in.
                try? controller.openOpticsForCalibration()
                controller.startRunning()
            }
            .onDisappear { controller.stopRunning() }
    }
}

/// Scene definition for the app.
///
/// Deliberately without `@main`. This module builds as a library so its logic
/// can be unit-tested, and a library cannot carry the app entry point. The
/// Xcode app target supplies a small file that does:
///
/// ```swift
/// import SwiftUI
/// import TJApp
///
/// @main
/// struct TripleJumpAppMain: App {
///     var body: some Scene { TripleJumpScene().body }
/// }
/// ```
public struct TripleJumpScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
