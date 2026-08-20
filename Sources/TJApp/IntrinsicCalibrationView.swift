import SwiftUI
import simd

/// Lens calibration screen.
///
/// The design goal is to make the invisible visible. Users cannot judge
/// whether a calibration is good by looking at a focal length in pixels, so
/// the screen shows the board being detected live, tracks which parts of the
/// frame still need coverage, and states the result in millimetres of error
/// on a real jump rather than in reprojection pixels.
public struct IntrinsicCalibrationView: View {

    @StateObject private var model: IntrinsicCalibrationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingRefocusConfirmation = false

    public var onComplete: (CameraIntrinsics) -> Void

    public init(store: IntrinsicsStore? = nil,
                captureController: CaptureController,
                preferredMode: CaptureRequirements.HardwareMode? = nil,
                onComplete: @escaping (CameraIntrinsics) -> Void) {
        _model = StateObject(wrappedValue: IntrinsicCalibrationViewModel(
            store: store,
            captureController: captureController,
            preferredMode: preferredMode))
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .requestingPermission, .configuring:
                ProgressView("Preparing camera")
                    .tint(.white)
                    .foregroundStyle(.white)

            case .collecting:
                collectingView

            case .solving:
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text("Solving lens calibration")
                        .foregroundStyle(.white)
                    Text("Refining \(model.capturedCount) views. This takes a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

            case .finished:
                resultView

            case .failed(let message):
                failureView(message)
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Collecting

    private var collectingView: some View {
        ZStack {
            CameraPreview(session: model.captureController.session)
                .ignoresSafeArea()

            CheckerboardOverlay(corners: model.detectedCorners,
                                imageSize: model.detectionImageSize,
                                columns: model.spec.columns,
                                rows: model.spec.rows,
                                colour: canCapture ? .green : .orange)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.capturedCount) of \(model.targetViews) views")
                    .font(.headline)
                    .foregroundStyle(.white)

                ProgressView(value: Double(model.capturedCount),
                             total: Double(model.targetViews))
                    .tint(.green)
                    .frame(width: 160)

                Text(model.guidance.message)
                    .font(.caption)
                    .foregroundStyle(model.guidance.canCapture ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .padding(10)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            Spacer()

            VStack(spacing: 6) {
                CoverageGridView(coverage: model.coverage)
                Text("frame coverage")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding()
    }

    /// Both conditions, not just the board one: a sharp, well-placed board
    /// photographed at a focus position that will not be used for recording
    /// produces a confident calibration of the wrong focal length.
    private var canCapture: Bool {
        model.guidance.canCapture && model.isFocusLocked
    }

    /// Focus is pinned once, before any view is captured, and every view
    /// shares it.
    ///
    /// Presented as a step of its own because it carries a physical
    /// instruction the app cannot carry out: the board has to be at roughly
    /// the distance the athlete will be. Pin the lens for a board held at
    /// arm's length and the runway six metres away records soft, which costs
    /// landmark precision exactly at the foot-ground boundary.
    private var focusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isFocusLocked
                  ? "camera.metering.spot" : "camera.metering.unknown")
                .foregroundStyle(model.isFocusLocked ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isFocusLocked ? "Focus pinned" : "Focus not pinned yet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(model.isFocusLocked
                     ? "Every view — and the recording — uses this focus."
                     : "Hold the board where the athlete will be, then pin.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                if model.isFocusLocked {
                    // Refocusing invalidates every view already captured, so
                    // it asks rather than quietly resetting the session.
                    if model.capturedCount > 0 {
                        showingRefocusConfirmation = true
                    } else {
                        Task { await model.refocus() }
                    }
                } else {
                    Task { await model.focusAndLock() }
                }
            } label: {
                if model.isFocusing {
                    ProgressView().tint(.white)
                } else {
                    Text(model.isFocusLocked ? "Refocus" : "Pin focus")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isFocusLocked ? .gray : .green)
            .disabled(model.isFocusing)
        }
        .padding(10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("Refocus and start over?",
                            isPresented: $showingRefocusConfirmation,
                            titleVisibility: .visible) {
            Button("Discard \(model.capturedCount) views and refocus",
                   role: .destructive) {
                Task { await model.refocus() }
            }
            Button("Keep current focus", role: .cancel) {}
        } message: {
            Text("Views already captured were taken at the current focus, and "
                 + "focal length changes with focus. They cannot be combined "
                 + "with views taken at a new one, so they will be discarded.")
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if !model.advice.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.advice, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text(item)
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            focusBar

            HStack(spacing: 24) {
                Button {
                    model.removeLastView()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.title2)
                }
                .disabled(model.capturedCount == 0)
                .foregroundStyle(.white)

                Button {
                    model.captureCurrentView()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(canCapture ? Color.green : Color.gray)
                            .frame(width: 58, height: 58)
                    }
                }
                .disabled(!canCapture)

                Button {
                    Task { await model.calibrate() }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill").font(.title2)
                        Text("Solve").font(.caption2)
                    }
                }
                .disabled(!model.canCalibrate)
                .foregroundStyle(model.canCalibrate ? .green : .white.opacity(0.4))
            }
            .padding(.bottom, 8)
        }
        .padding()
    }

    // MARK: - Result

    @ViewBuilder
    private var resultView: some View {
        if let result = model.result, let grade = model.grade {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: iconName(for: grade))
                            .font(.title)
                            .foregroundStyle(colour(for: grade))
                        VStack(alignment: .leading) {
                            Text(title(for: grade)).font(.title3.weight(.semibold))
                            Text("\(result.viewCount) views, \(result.iterations) iterations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let summary = model.qualitySummary {
                        Text(summary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Numbers second. What matters to the user is the
                    // millimetre figure above; these are for the record.
                    GroupBox("Measured values") {
                        Grid(alignment: .leading, horizontalSpacing: 18,
                             verticalSpacing: 5) {
                            row("Focal length x",
                                String(format: "%.1f px", result.intrinsics.focalLengthX))
                            row("Focal length y",
                                String(format: "%.1f px", result.intrinsics.focalLengthY))
                            row("Principal point",
                                String(format: "%.1f, %.1f",
                                       result.intrinsics.principalPointX,
                                       result.intrinsics.principalPointY))
                            row("Radial k1",
                                String(format: "%.5f", result.intrinsics.k1))
                            row("Radial k2",
                                String(format: "%.5f", result.intrinsics.k2))
                            row("Reprojection RMS",
                                String(format: "%.3f px", result.reprojectionRMSE))
                        }
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Applies to") {
                        Text(result.intrinsics.configurationFingerprint)
                            .font(.caption.monospaced())
                        Text("This calibration is valid only for this camera and "
                             + "capture mode. Recording in a different resolution or "
                             + "frame rate needs its own calibration, because "
                             + "high-frame-rate modes crop the sensor.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let worst = result.perViewRMSE.enumerated()
                        .max(by: { $0.element < $1.element }),
                       worst.element > result.reprojectionRMSE * 2 {
                        Label("View \(worst.offset + 1) fits noticeably worse than the "
                              + "rest (\(String(format: "%.2f", worst.element)) px). "
                              + "It was probably captured while the board or camera "
                              + "was moving.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button("Recapture") { model.resetViews() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Save calibration") {
                            Task {
                                if await model.saveResult() {
                                    onComplete(result.intrinsics)
                                    dismiss()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(grade == .rejected)
                    }
                }
                .padding()
            }
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await model.start() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func iconName(for grade: IntrinsicQuality.Grade) -> String {
        switch grade {
        case .excellent, .good: return "checkmark.circle.fill"
        case .acceptable: return "exclamationmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        }
    }

    private func colour(for grade: IntrinsicQuality.Grade) -> Color {
        switch grade {
        case .excellent: return .green
        case .good: return .mint
        case .acceptable: return .orange
        case .rejected: return .red
        }
    }

    private func title(for grade: IntrinsicQuality.Grade) -> String {
        switch grade {
        case .excellent: return "Excellent calibration"
        case .good: return "Good calibration"
        case .acceptable: return "Acceptable calibration"
        case .rejected: return "Calibration not usable"
        }
    }
}
