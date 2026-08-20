import SwiftUI
import AVFoundation

/// Pre-flight diagnostics.
///
/// This screen exists for device bring-up. Nothing in this project has run on
/// hardware, and the failures that matter here are the quiet ones: a format
/// requested at 240 fps that delivers 90, a stabilisation setter that is
/// accepted and ignored, a pose model that is in the repository but not in
/// the bundle. Each of those produces a working-looking app that yields wrong
/// numbers.
///
/// Every check below either passes with evidence or fails with the specific
/// remedy. None of them say "something went wrong".
public struct HardwareCheckView: View {

    @EnvironmentObject private var state: AppState
    @State private var results: [CheckResult] = []
    @State private var isRunning = false
    @State private var measuredRate: Double?

    // Hoisted out of the view body with an explicit type. Inline, this is a
    // chain of `+` on string literals inside a ViewBuilder, and each `+` is an
    // overload the type-checker has to resolve against everything else in the
    // section — enough, here, to push it past its time limit outright.
    private let frameRateFooter: String =
        "Records three seconds and counts the frames that actually arrived. "
        + "This is the number analysis uses — the requested rate is only a "
        + "request, and iOS abandons it in poor light without saying so."

    public init() {}

    public struct CheckResult: Identifiable {
        public let id = UUID()
        public var name: String
        public var status: Status
        public var detail: String

        public enum Status {
            case pass, warn, fail, skipped

            var icon: String {
                switch self {
                case .pass:    return "checkmark.circle.fill"
                case .warn:    return "exclamationmark.triangle.fill"
                case .fail:    return "xmark.circle.fill"
                case .skipped: return "minus.circle"
                }
            }

            var colour: Color {
                switch self {
                case .pass:    return .green
                case .warn:    return .orange
                case .fail:    return .red
                case .skipped: return .secondary
                }
            }
        }
    }

    public var body: some View {
        List {
            Section {
                Button {
                    Task { await runChecks() }
                } label: {
                    HStack {
                        if isRunning { ProgressView().controlSize(.small) }
                        Text(isRunning ? "Running checks" : "Run hardware checks")
                    }
                }
                .disabled(isRunning)
            } footer: {
                Text("Run this once on each new device, and again if measurements "
                     + "start disagreeing with a tape measure.")
            }

            if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.status.icon)
                                .foregroundStyle(result.status.colour)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.subheadline.weight(.medium))
                                Text(result.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Button {
                    Task { await measureDeliveredFrameRate() }
                } label: {
                    Label("Measure real frame rate (3 s recording)",
                          systemImage: "speedometer")
                }
                .disabled(isRunning || state.captureConfiguration == nil)

                if let measuredRate {
                    LabeledContent("Delivered",
                                   value: String(format: "%.1f fps", measuredRate))
                    .foregroundStyle(measuredRate >= CaptureRequirements.minimumFrameRate
                                     ? Color.primary : Color.red)
                }
            } header: {
                Text("Frame rate under load")
            } footer: {
                Text(frameRateFooter)
            }
        }
        .navigationTitle("Hardware check")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Checks

    private func runChecks() async {
        isRunning = true
        defer { isRunning = false }
        var found = [CheckResult]()

        // --- Permission ---
        let authorised = await CaptureController.requestPermission()
        found.append(CheckResult(
            name: "Camera permission",
            status: authorised ? .pass : .fail,
            detail: authorised
                ? "Granted."
                : "Denied. Settings › Privacy & Security › Camera, then enable this app."))

        guard authorised else { results = found; return }

        // --- Device and format ---
        if AVCaptureDevice.default(.builtInWideAngleCamera,
                                   for: .video, position: .back) != nil {
            let supported = CaptureController.supportedModes()
            let ranked = CaptureRequirements.preferredModes

            for candidate in ranked {
                let available = supported.contains(candidate)
                found.append(CheckResult(
                    name: "Mode \(candidate.label)",
                    status: available ? .pass : .skipped,
                    detail: available
                        ? "Available."
                        : "Not offered by this camera."))
            }

            if let selected = supported.first {
                found.append(CheckResult(
                    name: "Mode that will be selected",
                    status: selected.frameRate >= 240 ? .pass : .warn,
                    detail: selected.frameRate >= 240
                        ? "\(selected.label) — the highest-preference mode this "
                        + "device supports."
                        : "\(selected.label). This device has no 240 fps mode, so "
                        + "contact timing lands at ±14 ms rather than the ±7 ms "
                        + "the 240 fps modes give with confirmed events."))
            } else {
                found.append(CheckResult(
                    name: "Mode that will be selected",
                    status: .fail,
                    detail: "None of the three supported modes are offered by this "
                          + "camera. This device cannot record at the "
                          + "\(Int(CaptureRequirements.minimumFrameRate)) fps floor "
                          + "the analysis needs."))
            }
        } else {
            found.append(CheckResult(name: "Rear camera", status: .fail,
                                     detail: "No rear wide-angle camera found."))
        }

        // --- Configure, which exercises pinning and stabilisation ---
        do {
            let configuration = try state.captureController.configure(mode: .recording)
            found.append(CheckResult(
                name: "Frame duration pinned",
                status: .pass,
                detail: "Min and max frame duration both set to 1/"
                      + "\(Int(configuration.frameRate)) s. Without both, iOS is free "
                      + "to slow down for exposure."))
            found.append(CheckResult(
                name: "Video stabilisation off",
                status: .pass,
                detail: "Disabled and verified. Stabilisation warps image geometry "
                      + "per frame, which would break the fixed camera-to-world map "
                      + "every distance depends on."))
            found.append(CheckResult(
                name: "Capture fingerprint",
                status: .pass,
                detail: configuration.fingerprint))
        } catch let error as CaptureControllerError {
            let isStabilisation = {
                if case .stabilisationCouldNotBeDisabled = error { return true }
                return false
            }()
            found.append(CheckResult(
                name: isStabilisation ? "Video stabilisation off" : "Camera configuration",
                status: .fail,
                detail: error.localizedDescription))
        } catch {
            found.append(CheckResult(name: "Camera configuration", status: .fail,
                                     detail: error.localizedDescription))
        }

        // --- Pose model ---
        let modelPresent = Bundle.main.path(
            forResource: PoseModelBundle.filename, ofType: "task") != nil
        found.append(CheckResult(
            name: "Pose model in bundle",
            status: modelPresent ? .pass : .fail,
            detail: modelPresent
                ? "\(PoseModelBundle.filename).task found."
                : "\(PoseModelBundle.filename).task is missing. Download it from the "
                + "MediaPipe model garden and add it to the app target with Target "
                + "Membership ticked. Without it, recording works and analysis fails."))

        // --- MediaPipe linkage ---
        found.append(CheckResult(
            name: "MediaPipe linked",
            status: PoseModelBundle.frameworkAvailable ? .pass : .fail,
            detail: PoseModelBundle.frameworkAvailable
                ? "MediaPipeTasksVision is linked."
                : "Not linked. Add `pod 'MediaPipeTasksVision', '~> 0.10.14'` to the "
                + "Podfile, run pod install, and open the .xcworkspace."))

        // --- Calibration state ---
        if let intrinsics = state.intrinsics {
            found.append(CheckResult(
                name: "Lens calibration",
                status: intrinsics.calibrationRMSE <= IntrinsicQuality.acceptableRMSE
                    ? .pass : .warn,
                detail: String(format: "%.2f px fit for %@.",
                               intrinsics.calibrationRMSE,
                               intrinsics.configurationFingerprint)))
        } else {
            found.append(CheckResult(
                name: "Lens calibration",
                status: .skipped,
                detail: "Not measured yet for this capture mode."))
        }

        // --- Thermal and storage ---
        found.append(CheckResult(
            name: "Thermal state",
            status: state.captureController.thermalWarning == nil ? .pass : .warn,
            detail: state.captureController.thermalWarning
                ?? "Nominal. Sustained 240 fps capture heats a phone quickly, so "
                + "re-check this after a long session."))

        if let configuration = state.captureConfiguration {
            do {
                try CaptureController.checkStorage(forSeconds: 60,
                                                   configuration: configuration)
                found.append(CheckResult(
                    name: "Free storage",
                    status: .pass,
                    detail: "Room for at least a minute of recording."))
            } catch {
                found.append(CheckResult(name: "Free storage", status: .warn,
                                         detail: error.localizedDescription))
            }
        }

        results = found
    }

    /// Record three seconds and report what actually arrived.
    private func measureDeliveredFrameRate() async {
        isRunning = true
        defer { isRunning = false }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratecheck.mov")
        do {
            state.captureController.startRunning()
            try state.captureController.startRecording(to: url)
            try? await Task.sleep(for: .seconds(3))
            let clip = try await state.captureController.stopRecording()
            measuredRate = clip.measuredFrameRate
            try? FileManager.default.removeItem(at: url)
        } catch {
            measuredRate = nil
            results.append(CheckResult(name: "Frame rate measurement",
                                       status: .fail,
                                       detail: error.localizedDescription))
        }
    }
}

/// Where the pose model lives, and whether the framework is linked.
///
/// Split out so `HardwareCheckView` can report on both without importing
/// MediaPipe itself — the whole point is that this screen still runs, and
/// still tells you what is missing, when MediaPipe is absent.
public enum PoseModelBundle {

    public static let filename = "pose_landmarker_heavy"

    public static var frameworkAvailable: Bool {
        #if canImport(MediaPipeTasksVision)
        return true
        #else
        return false
        #endif
    }

    public static var modelPresent: Bool {
        Bundle.main.path(forResource: filename, ofType: "task") != nil
    }

    /// Everything needed for analysis is in place.
    public static var ready: Bool { frameworkAvailable && modelPresent }
}
