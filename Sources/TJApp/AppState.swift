import Foundation
import SwiftUI
import AVFoundation

/// App-wide state and the single owner of every store.
///
/// One object rather than several environment values because the pieces are
/// genuinely interdependent: whether recording is allowed depends on the lens
/// calibration, which depends on the capture configuration, which must match
/// the selected tripod profile. Scattering those across independent sources
/// makes it possible for the UI to offer an action that cannot succeed.
@MainActor
public final class AppState: ObservableObject {

    // MARK: Published

    @Published public private(set) var profiles: [CalibrationProfile] = []
    @Published public private(set) var sessions: [StoredSession] = []
    @Published public private(set) var intrinsics: CameraIntrinsics?
    @Published public private(set) var captureConfiguration: CaptureConfiguration?
    @Published public var startupError: String?
    @Published public private(set) var retentionNotice: String?

    @Published public var selectedProfileID: UUID? {
        didSet { UserDefaults.standard.set(selectedProfileID?.uuidString,
                                           forKey: Self.selectedProfileKey) }
    }

    @Published public var athleteName: String = "" {
        didSet { UserDefaults.standard.set(athleteName, forKey: Self.athleteKey) }
    }

    /// Explicit override of the automatic ranked mode selection, for the
    /// coach who wants 1080p at 120 fps deliberately — better low-light
    /// sensitivity per frame, traded for coarser contact timing — rather
    /// than whatever the device would pick on its own. `nil` means let
    /// `CaptureController` pick the highest-preference mode the hardware
    /// supports, which is the right default for almost everyone.
    ///
    /// Change it through `setPreferredCaptureMode(_:)`, not by assigning
    /// directly — that method also reconfigures the camera and reloads the
    /// matching intrinsics, and doing that from an explicit call rather than
    /// a property observer keeps the failure path (a mode the device
    /// claimed to support at enumeration time can still be rejected at
    /// configure time) somewhere it can actually be reported.
    @Published public private(set) var preferredCaptureMode: CaptureRequirements.HardwareMode?

    // MARK: Stores

    public private(set) var intrinsicsStore: IntrinsicsStore?
    public private(set) var profileStore: CalibrationProfileStore?
    public private(set) var sessionStore: SessionStore?
    public let captureController = CaptureController()

    /// Nil until the stores exist. The correction screen degrades gracefully
    /// when it is nil rather than crashing, which is what makes the app
    /// usable before MediaPipe is integrated.
    public private(set) var analysisRunner: AnalysisRunner?

    private static let selectedProfileKey = "selectedProfileID"
    private static let athleteKey = "athleteName"
    private static let preferredModeKey = "preferredCaptureModeFingerprint"

    public init() {
        if let stored = UserDefaults.standard.string(forKey: Self.selectedProfileKey) {
            selectedProfileID = UUID(uuidString: stored)
        }
        athleteName = UserDefaults.standard.string(forKey: Self.athleteKey) ?? ""

        if let fingerprint = UserDefaults.standard.string(forKey: Self.preferredModeKey) {
            preferredCaptureMode = CaptureRequirements.preferredModes
                .first { $0.fingerprint == fingerprint }
        }
    }

    // MARK: Derived

    public var selectedProfile: CalibrationProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    /// Focus position the selected profile was calibrated at, if it recorded
    /// one. Profiles calibrated before focus position was tracked return
    /// `nil`, and recording then falls back to freezing the lens where it is.
    public var calibratedLensPosition: Float? {
        selectedProfile?.intrinsics.lensPosition.map(Float.init)
    }

    /// Re-configure the session immediately before recording.
    ///
    /// The startup configure runs before any profile is loaded — it exists to
    /// establish the fingerprint that *selects* the profile, so it cannot
    /// know the focus position yet. Without this second pass the lens would
    /// be locked wherever it happened to sit, and the footage would be shot
    /// at a different focal length from the one the intrinsics describe:
    /// every distance scaled by a factor nothing downstream can detect.
    public func prepareCaptureSession() {
        do {
            captureConfiguration = try captureController.configure(
                mode: .recording,
                preferring: preferredCaptureMode,
                lensPosition: calibratedLensPosition)
        } catch {
            startupError = error.localizedDescription
        }
    }

    /// How far through setup the user is.
    ///
    /// Ordered, not a set of independent flags, because the steps genuinely
    /// depend on each other: the lens calibration scales everything, the
    /// tripod solve needs the lens, and analysis needs both. Reporting them
    /// as peers would invite starting in the middle and getting numbers that
    /// look plausible and are wrong.
    public enum Readiness: Equatable {
        case needsPermission
        case needsIntrinsics
        case needsProfile
        case profileMismatch(String)
        case ready

        public var title: String {
            switch self {
            case .needsPermission:  return "Camera access needed"
            case .needsIntrinsics:  return "Lens not calibrated yet"
            case .needsProfile:     return "No tripod profile"
            case .profileMismatch:  return "Profile does not match this camera mode"
            case .ready:            return "Ready to record"
            }
        }

        public var detail: String {
            switch self {
            case .needsPermission:
                return "Turn on camera access in Settings › Privacy & Security › Camera."
            case .needsIntrinsics:
                return "Measure the lens once for this phone and capture mode. "
                     + "Everything else is scaled by it."
            case .needsProfile:
                return "Set up the tripod, then tap the board corners and the "
                     + "reference pipe to solve the camera position."
            case .profileMismatch(let detail):
                return detail
            case .ready:
                return "Calibration is in place. Recorded jumps will be comparable "
                     + "with earlier sessions on this profile."
            }
        }
    }

    public var readiness: Readiness {
        if AVCaptureDeviceAuthorization.isDenied { return .needsPermission }
        guard let intrinsics else { return .needsIntrinsics }
        guard let profile = selectedProfile else { return .needsProfile }
        guard profile.intrinsics.configurationFingerprint
                == intrinsics.configurationFingerprint else {
            return .profileMismatch(
                "This profile was solved against a different capture mode "
                + "(\(profile.intrinsics.configurationFingerprint)). Lens calibration "
                + "does not transfer between modes, so measurements would be scaled "
                + "incorrectly. Re-solve the tripod profile in the current mode.")
        }
        return .ready
    }

    public var canRecord: Bool { readiness == .ready }

    // MARK: Bootstrap

    public func bootstrap() async {
        do {
            let intrinsicsStore = try IntrinsicsStore()
            let profileStore = try CalibrationProfileStore()
            let sessionStore = try SessionStore()

            self.intrinsicsStore = intrinsicsStore
            self.profileStore = profileStore
            self.sessionStore = sessionStore
            self.analysisRunner = AnalysisRunner(
                sessionStore: sessionStore,
                profileStore: profileStore,
                poseExtractor: try? PoseEstimator())

            // Configure the camera before loading intrinsics: the
            // configuration determines the fingerprint, and the fingerprint
            // determines which stored calibration is the right one.
            if await CaptureController.requestPermission() {
                captureConfiguration = try? captureController.configure(
                    mode: .recording, preferring: preferredCaptureMode)
            }

            if let fingerprint = captureConfiguration?.fingerprint {
                intrinsics = await intrinsicsStore.load(fingerprint: fingerprint)
            }

            profiles = (try? await profileStore.loadAll()) ?? []
            if selectedProfileID == nil || !profiles.contains(where: {
                $0.id == selectedProfileID
            }) {
                selectedProfileID = profiles.first?.id
            }

            await refreshSessions()
            await runRetentionSweep()

        } catch {
            startupError = error.localizedDescription
        }
    }

    public func refreshSessions() async {
        guard let sessionStore else { return }
        sessions = (try? await sessionStore.loadAll()) ?? []
    }

    /// Drop footage past its three-day window, and say so.
    ///
    /// Run once at launch rather than on a timer. Silent deletion of a
    /// coach's footage is indistinguishable from a bug, so the count of what
    /// went is surfaced rather than logged.
    private func runRetentionSweep() async {
        guard let sessionStore else { return }
        guard let dropped = try? await sessionStore.pruneExpiredVideos(),
              !dropped.isEmpty else { return }
        retentionNotice = dropped.count == 1
            ? "Footage from 1 trial passed its three-day window and was removed. "
            + "Its measurements are unchanged."
            : "Footage from \(dropped.count) trials passed their three-day window and "
            + "was removed. Their measurements are unchanged."
        await refreshSessions()
    }

    public func dismissRetentionNotice() { retentionNotice = nil }

    /// Modes this specific device actually offers, most-preferred first.
    /// Empty until `bootstrap()` has requested camera permission at least
    /// once; the settings screen shows a "checking…" state rather than an
    /// empty picker in that gap.
    public var supportedCaptureModes: [CaptureRequirements.HardwareMode] {
        CaptureController.supportedModes()
    }

    // MARK: Mutations

    public func setIntrinsics(_ value: CameraIntrinsics) {
        intrinsics = value
    }

    /// Change the recording mode override and reconfigure the camera to
    /// match.
    ///
    /// Called explicitly from `SettingsView` after the picker changes,
    /// rather than from a property observer — the reconfiguration is async
    /// and can fail (a mode the device claims to support at enumeration time
    /// could still be rejected at configure time), and a failure needs
    /// somewhere to report to, which a `didSet` does not have.
    ///
    /// `intrinsics` is deliberately re-read for the new fingerprint rather
    /// than cleared and left for `bootstrap` to find on next launch — a
    /// coach who switches modes mid-session to fight failing light should
    /// see the readiness checklist correctly ask for a fresh lens
    /// calibration immediately, not after relaunching the app.
    public func setPreferredCaptureMode(
        _ mode: CaptureRequirements.HardwareMode?) async {
        preferredCaptureMode = mode
        UserDefaults.standard.set(mode?.fingerprint, forKey: Self.preferredModeKey)

        do {
            captureConfiguration = try captureController.configure(
                mode: .recording, preferring: mode)
        } catch {
            startupError = error.localizedDescription
            return
        }

        intrinsics = nil
        if let fingerprint = captureConfiguration?.fingerprint {
            intrinsics = await intrinsicsStore?.load(fingerprint: fingerprint)
        }
    }

    public func addProfile(_ profile: CalibrationProfile) async {
        guard let profileStore else { return }
        do {
            try await profileStore.save(profile)
            profiles = (try? await profileStore.loadAll()) ?? []
            selectedProfileID = profile.id
        } catch {
            startupError = error.localizedDescription
        }
    }

    public func deleteProfile(id: UUID) async {
        guard let profileStore else { return }
        try? await profileStore.delete(id: id)
        profiles = (try? await profileStore.loadAll()) ?? []
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
    }

    // MARK: Recording

    /// Analyse a finished clip and store it.
    ///
    /// Returns nil and sets `startupError` on failure rather than throwing,
    /// because every caller is a SwiftUI action that would otherwise need its
    /// own error plumbing for the same three failure modes.
    public func analyse(clip: CapturedClip,
                        progress: @Sendable @escaping (AnalysisRunner.AnalysisProgress) -> Void)
        async -> StoredSession? {

        guard let analysisRunner, let profile = selectedProfile else {
            startupError = "No calibration profile is selected."
            return nil
        }

        do {
            let session = try await analysisRunner.analyse(
                clip: clip,
                profile: profile,
                athleteName: athleteName.isEmpty ? "Unnamed athlete" : athleteName,
                progress: progress)
            await refreshSessions()
            profiles = (try? await profileStore?.loadAll()) ?? profiles
            return session
        } catch {
            startupError = error.localizedDescription
            return nil
        }
    }
}

/// Permission state, named so `readiness` reads as a sentence.
enum AVCaptureDeviceAuthorization {
    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }
}
