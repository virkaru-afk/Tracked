import SwiftUI
import AVFoundation
import simd

/// Solving the camera position by tapping six reference points.
///
/// Named `TripodCalibrationView` rather than `CalibrationView` because
/// `IntrinsicCalibrator.swift` already defines `CalibrationView` as the data
/// type for one captured checkerboard view. Two different things with one
/// name in the same module is a collision, and the data type came first.
///
/// The whole screen is built around one measured fact: tap precision
/// dominates calibration error, at roughly 10 mm of recovered distance
/// uncertainty per 2 px of tap noise. Everything here — the loupe, the nudge
/// arrows, the deliberate one-point-at-a-time flow — exists to buy pixels
/// back. Thirty extra seconds spent here measurably improves every session
/// recorded against the resulting profile.
public struct TripodCalibrationView: View {

    @StateObject private var model: TripodCalibrationModel
    @Environment(\.dismiss) private var dismiss

    public let session: AVCaptureSession
    public let onComplete: (CalibrationProfile) -> Void

    public init(intrinsics: CameraIntrinsics,
                imageSize: CGSize,
                session: AVCaptureSession,
                onComplete: @escaping (CalibrationProfile) -> Void) {
        _model = StateObject(wrappedValue: TripodCalibrationModel(
            intrinsics: intrinsics, imageSize: imageSize))
        self.session = session
        self.onComplete = onComplete
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .measurements: measurementsForm
                case .tapping:      tappingView
                case .result:       resultView
                }
            }
            .navigationTitle(model.stage.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Stage 1 — measurements

    private var measurementsForm: some View {
        Form {
            Section {
                LabeledContent("Lens height") {
                    HStack {
                        TextField("1.20", value: $model.tripodHeight, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("m")
                    }
                }
            } header: {
                Text("Tripod")
            } footer: {
                Text("Ground to the middle of the lens, measured with a tape. "
                     + "±20 mm is fine — this is used as a soft prior that steers the "
                     + "solve, not as fact.")
            }

            Section {
                LabeledContent("Marker height") {
                    HStack {
                        TextField("1.50", value: $model.pipeHeight, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("m")
                    }
                }
            } header: {
                Text("Reference pipe")
            } footer: {
                Text("Ground to the centre of the marker on top. Enter what you "
                     + "actually measured, not what the pipe is nominally — a 1.48 m "
                     + "pipe entered as 1.50 puts a 1.3% scale error into every "
                     + "distance the app reports.")
            }

            Section {
                Button("Start tapping points") {
                    model.stage = .tapping
                }
                .disabled(!model.measurementsValid)
            } footer: {
                if !model.measurementsValid {
                    Text("Both heights must be between 0.3 m and 3 m.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Stage 2 — tapping

    private var tappingView: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    CameraPreview(session: session)

                    TapTargetOverlay(model: model, viewSize: geometry.size)

                    // Loupe. Tap precision is the dominant error source, and
                    // a fingertip covers roughly 40 px of a phone screen —
                    // the magnifier is what makes a 2 px tap achievable at
                    // all.
                    if let target = model.pendingPoint {
                        LoupeView(model: model,
                                  target: target,
                                  viewSize: geometry.size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.setPending(viewPoint: value.location,
                                             viewSize: geometry.size)
                        }
                )
            }

            tappingControls
        }
    }

    private var tappingControls: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentPointLabel)
                        .font(.headline)
                    Text(model.currentPointHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(model.placedCount) / 6")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // Nudge pad. One tap is one pixel — the unit that matters, since
            // 2 px of error is 10 mm of recovered distance.
            HStack(spacing: 20) {
                nudgeButton(dx: -1, dy: 0, icon: "arrow.left")
                VStack(spacing: 8) {
                    nudgeButton(dx: 0, dy: -1, icon: "arrow.up")
                    nudgeButton(dx: 0, dy: 1, icon: "arrow.down")
                }
                nudgeButton(dx: 1, dy: 0, icon: "arrow.right")

                Spacer()

                Button {
                    model.undoLastPoint()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .disabled(model.placedCount == 0 && model.pendingPoint == nil)

                Button {
                    model.confirmPending()
                } label: {
                    Text(model.placedCount == 5 ? "Place and solve" : "Place point")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingPoint == nil)
            }

            if model.isSolving {
                ProgressView("Solving camera position")
                    .font(.caption)
            }
            if let error = model.solveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private func nudgeButton(dx: Double, dy: Double, icon: String) -> some View {
        Button {
            model.nudgePending(dx: dx, dy: dy)
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.bordered)
        .disabled(model.pendingPoint == nil)
    }

    // MARK: Stage 3 — result

    @ViewBuilder
    private var resultView: some View {
        if let result = model.result {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: iconName(for: model.grade))
                            .font(.title)
                            .foregroundStyle(colour(for: model.grade))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: model.grade))
                                .font(.headline)
                            Text(String(format: "%.2f px fit · %.2f m from board",
                                        result.reprojectionRMSE, result.pose.distance))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let advice = CalibrationQuality.advice(result) {
                        Label(advice, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Recovered geometry") {
                    LabeledContent("Distance from board",
                                   value: String(format: "%.2f m", result.pose.distance))
                    LabeledContent("Lens height",
                                   value: String(format: "%.2f m", result.pose.height))
                    LabeledContent("Yaw",
                                   value: String(format: "%.1f°", result.pose.yawDegrees))
                    LabeledContent("Pitch",
                                   value: String(format: "%.1f°", result.pose.pitchDegrees))
                    LabeledContent("Worst point error",
                                   value: String(format: "%.2f px", result.maxPointError))
                }
                .font(.callout.monospacedDigit())

                Section {
                    TextField("North runway, 4 m mark", text: $model.profileName)
                } header: {
                    Text("Profile name")
                } footer: {
                    Text("Name it after the physical setup, not the date. You will "
                         + "reuse this profile every session you record from this spot.")
                }

                Section {
                    TextEditor(text: $model.setupNotes)
                        .frame(minHeight: 90)
                } header: {
                    Text("Setup notes")
                } footer: {
                    Text("Where the tripod legs are taped, where the pipe base is, "
                         + "which runway. Reusing this profile instead of re-solving "
                         + "measured 4× better session-to-session repeatability, and "
                         + "that only works if you can rebuild the rig exactly.")
                }

                Section {
                    Button("Save profile") {
                        if let profile = model.buildProfile() {
                            onComplete(profile)
                            dismiss()
                        }
                    }
                    .disabled(model.grade == .rejected || model.profileName.isEmpty)

                    Button("Re-tap the points", role: .destructive) {
                        model.restartTapping()
                    }
                }
            }
        }
    }

    private func iconName(for grade: CalibrationQuality.Grade?) -> String {
        switch grade {
        case .excellent, .acceptable: return "checkmark.circle.fill"
        case .poor:                   return "exclamationmark.circle.fill"
        case .rejected, .none:        return "xmark.circle.fill"
        }
    }

    private func colour(for grade: CalibrationQuality.Grade?) -> Color {
        switch grade {
        case .excellent:       return .green
        case .acceptable:      return .mint
        case .poor:            return .orange
        case .rejected, .none: return .red
        }
    }

    private func title(for grade: CalibrationQuality.Grade?) -> String {
        switch grade {
        case .excellent:  return "Excellent calibration"
        case .acceptable: return "Good calibration"
        case .poor:       return "Usable, but the tripod is off square"
        case .rejected:   return "Calibration not usable"
        case .none:       return "No result"
        }
    }
}

// MARK: - Model

@MainActor
public final class TripodCalibrationModel: ObservableObject {

    public enum Stage: Equatable {
        case measurements, tapping, result

        var title: String {
            switch self {
            case .measurements: return "Measurements"
            case .tapping:      return "Tap reference points"
            case .result:       return "Calibration result"
            }
        }
    }

    @Published public var stage: Stage = .measurements
    @Published public var tripodHeight: Double = 1.20
    @Published public var pipeHeight: Double = 1.50
    @Published public var profileName: String = ""
    @Published public var setupNotes: String = ""

    /// Points placed so far, in image pixel coordinates.
    @Published public private(set) var placedPoints: [SIMD2<Double>] = []
    /// The point being positioned, before it is committed.
    @Published public private(set) var pendingPoint: SIMD2<Double>?

    @Published public private(set) var result: CalibrationResult?
    @Published public private(set) var grade: CalibrationQuality.Grade?
    @Published public private(set) var isSolving = false
    @Published public private(set) var solveError: String?

    public let intrinsics: CameraIntrinsics
    public let imageSize: CGSize

    private var observations: CalibrationObservations?

    public init(intrinsics: CameraIntrinsics, imageSize: CGSize) {
        self.intrinsics = intrinsics
        self.imageSize = imageSize
    }

    public var measurementsValid: Bool {
        (0.3...3.0).contains(tripodHeight) && (0.3...3.0).contains(pipeHeight)
    }

    public var placedCount: Int { placedPoints.count }

    /// Labels in the exact tap order `WorldFrame.boardCorners` assumes.
    /// Changing this order silently solves for a different camera.
    public static let pointLabels = WorldFrame.boardCornerLabels
        + ["Pipe base", "Pipe top"]

    private static let pointHints = [
        "The board corner closest to the camera, on the pit side of the white line.",
        "The far board corner, same side of the white line.",
        "The far corner on the back edge of the board, away from the pit.",
        "The near corner on the back edge, closest to the camera.",
        "Where the reference pipe meets the ground.",
        "The centre of the marker on top of the pipe.",
    ]

    public var currentPointLabel: String {
        let index = min(placedCount, Self.pointLabels.count - 1)
        return "\(index + 1). \(Self.pointLabels[index])"
    }

    public var currentPointHint: String {
        let index = min(placedCount, Self.pointHints.count - 1)
        return Self.pointHints[index]
    }

    // MARK: Tapping

    public func setPending(viewPoint: CGPoint, viewSize: CGSize) {
        guard placedCount < 6 else { return }
        let mapping = AspectFitMapping(imageSize: imageSize, viewSize: viewSize)
        let image = mapping.imagePoint(fromView: viewPoint)
        // Clamp into the frame. A tap on the letterbox bar maps outside the
        // image, and a negative pixel coordinate would be solved against
        // without complaint.
        pendingPoint = SIMD2(min(max(image.x, 0), Double(imageSize.width)),
                             min(max(image.y, 0), Double(imageSize.height)))
    }

    public func nudgePending(dx: Double, dy: Double) {
        guard var point = pendingPoint else { return }
        point.x = min(max(point.x + dx, 0), Double(imageSize.width))
        point.y = min(max(point.y + dy, 0), Double(imageSize.height))
        pendingPoint = point
    }

    public func confirmPending() {
        guard let pendingPoint, placedCount < 6 else { return }
        placedPoints.append(pendingPoint)
        self.pendingPoint = nil
        if placedPoints.count == 6 { solve() }
    }

    public func undoLastPoint() {
        if pendingPoint != nil {
            pendingPoint = nil
        } else if !placedPoints.isEmpty {
            placedPoints.removeLast()
        }
        solveError = nil
    }

    public func restartTapping() {
        placedPoints.removeAll()
        pendingPoint = nil
        result = nil
        grade = nil
        solveError = nil
        stage = .tapping
    }

    // MARK: Solving

    private func solve() {
        isSolving = true
        solveError = nil

        let pipe = ReferencePipe(height: pipeHeight)
        let observations = CalibrationObservations(
            boardCorners: Array(placedPoints.prefix(4)),
            pipeBase: placedPoints[4],
            pipeTop: placedPoints[5],
            measuredTripodHeight: tripodHeight)
        self.observations = observations

        let solver = CalibrationSolver(intrinsics: intrinsics, pipe: pipe)

        do {
            let outcome = try solver.solve(observations: observations)
            result = outcome
            grade = CalibrationQuality.grade(outcome)
            stage = .result
        } catch {
            solveError = error.localizedDescription
            // Keep the taps. Making the user redo all six because the sixth
            // was slightly off is the fastest way to make them stop bothering
            // with calibration at all.
            placedPoints.removeLast()
        }
        isSolving = false
    }

    public func buildProfile() -> CalibrationProfile? {
        guard let result, let observations else { return nil }
        return CalibrationProfile(name: profileName,
                                  intrinsics: intrinsics,
                                  pose: result.pose,
                                  pipe: ReferencePipe(height: pipeHeight),
                                  observations: observations,
                                  reprojectionRMSE: result.reprojectionRMSE,
                                  maxPointError: result.maxPointError,
                                  setupNotes: setupNotes)
    }
}

// MARK: - Overlays

struct TapTargetOverlay: View {

    @ObservedObject var model: TripodCalibrationModel
    let viewSize: CGSize

    var body: some View {
        let mapping = AspectFitMapping(imageSize: model.imageSize, viewSize: viewSize)

        ZStack {
            ForEach(Array(model.placedPoints.enumerated()), id: \.offset) { index, point in
                let position = mapping.viewPoint(fromImage: point)
                ZStack {
                    Circle()
                        .strokeBorder(.green, lineWidth: 2)
                        .frame(width: 18, height: 18)
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .offset(x: 14, y: -12)
                }
                .position(position)
            }

            if let pending = model.pendingPoint {
                let position = mapping.viewPoint(fromImage: pending)
                Crosshair()
                    .stroke(.yellow, lineWidth: 1)
                    .frame(width: 44, height: 44)
                    .position(position)
            }
        }
        .allowsHitTesting(false)
    }
}

struct Crosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let gap: CGFloat = 4
        path.move(to: CGPoint(x: rect.minX, y: centre.y))
        path.addLine(to: CGPoint(x: centre.x - gap, y: centre.y))
        path.move(to: CGPoint(x: centre.x + gap, y: centre.y))
        path.addLine(to: CGPoint(x: rect.maxX, y: centre.y))
        path.move(to: CGPoint(x: centre.x, y: rect.minY))
        path.addLine(to: CGPoint(x: centre.x, y: centre.y - gap))
        path.move(to: CGPoint(x: centre.x, y: centre.y + gap))
        path.addLine(to: CGPoint(x: centre.x, y: rect.maxY))
        path.addEllipse(in: CGRect(x: centre.x - 1, y: centre.y - 1,
                                   width: 2, height: 2))
        return path
    }
}

/// Magnified readout of the pending point.
///
/// Shows the pixel coordinate rather than a magnified image: the preview
/// layer's pixels are not addressable from SwiftUI without a second capture
/// path, and the number plus a crosshair is what the nudge arrows actually
/// operate on. Positioned opposite the point so a thumb on the screen does
/// not cover it.
struct LoupeView: View {

    @ObservedObject var model: TripodCalibrationModel
    let target: SIMD2<Double>
    let viewSize: CGSize

    var body: some View {
        let mapping = AspectFitMapping(imageSize: model.imageSize, viewSize: viewSize)
        let position = mapping.viewPoint(fromImage: target)
        let onLeft = position.x > viewSize.width / 2

        VStack(alignment: .leading, spacing: 2) {
            Text(model.currentPointLabel)
                .font(.caption2.weight(.semibold))
            Text(String(format: "x %.0f   y %.0f", target.x, target.y))
                .font(.caption.monospacedDigit())
            Text("Nudge to within 2 px")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .position(x: onLeft ? 90 : viewSize.width - 90, y: 60)
    }
}
