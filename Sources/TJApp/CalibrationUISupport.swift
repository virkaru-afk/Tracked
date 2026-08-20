import SwiftUI
import UIKit
import AVFoundation
import simd

/// Live camera preview, showing exactly the pixels the analysis sees.
public struct CameraPreview: UIViewRepresentable {

    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        // Aspect-fit, not fill. Filling crops the frame, and every tap
        // coordinate on this preview is converted back to image pixels for
        // the solver — a crop the conversion did not know about would put a
        // constant offset into every calibration.
        view.previewLayer.videoGravity = .resizeAspect
        view.applyBufferAlignedRotation()
        return view
    }

    public func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        // Re-applied on every update: the connection does not exist until a
        // session with an input is attached, so the value set in
        // `makeUIView` can land on nothing.
        view.applyBufferAlignedRotation()
    }

    public final class PreviewView: UIView {
        public override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        public var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        /// Show the sample buffer unrotated, matching what analysis receives.
        ///
        /// A preview connection defaults to `videoRotationAngle = 90` —
        /// portrait — while the sample buffers handed to the pose model and
        /// the checkerboard detector are never rotated at all. Nothing in
        /// this project used to set this, so the preview sat 90° away from
        /// the buffers, with two consequences:
        ///
        /// 1. Moving the phone along one axis moved the picture along the
        ///    perpendicular screen axis, which is disorienting to frame with.
        /// 2. Worse and silent: `AspectFitMapping` converts taps to image
        ///    pixels assuming the preview and the buffer share axes. Against
        ///    a 90°-rotated preview every tapped board corner and reference
        ///    point went to the solver with its coordinates transposed, and
        ///    the solve still returned a plausible-looking camera pose.
        ///
        /// Zero, not "whatever is upright". The tap mapping is only correct
        /// when preview pixels and buffer pixels are the same pixels, so the
        /// rotation is pinned and the *interface* orientation is chosen to
        /// suit it (`UISupportedInterfaceOrientations` in Info.plist). If the
        /// picture appears upside down on the tripod, the fix is to switch
        /// that key to the opposite landscape orientation — not to rotate
        /// here, which would put the mapping back out by 180°.
        func applyBufferAlignedRotation() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }
    }
}

/// Maps between image pixel coordinates and view coordinates under
/// aspect-fit letterboxing.
///
/// Every tap the user makes is a view coordinate; every coordinate the solver
/// wants is an image pixel. Getting this wrong does not look wrong — the taps
/// land visually where intended and the solve returns a plausible camera
/// position that is simply not the real one.
public struct AspectFitMapping {

    public let imageSize: CGSize
    public let viewSize: CGSize

    public init(imageSize: CGSize, viewSize: CGSize) {
        self.imageSize = imageSize
        self.viewSize = viewSize
    }

    public var scale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width,
                   viewSize.height / imageSize.height)
    }

    /// Letterbox offset: the blank bars either side of the fitted image.
    public var offset: CGPoint {
        CGPoint(x: (viewSize.width - imageSize.width * scale) / 2,
                y: (viewSize.height - imageSize.height * scale) / 2)
    }

    public func viewPoint(fromImage point: SIMD2<Double>) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * scale + offset.x,
                y: CGFloat(point.y) * scale + offset.y)
    }

    public func imagePoint(fromView point: CGPoint) -> SIMD2<Double> {
        SIMD2(Double((point.x - offset.x) / scale),
              Double((point.y - offset.y) / scale))
    }
}

/// Draws detected checkerboard corners over the preview.
public struct CheckerboardOverlay: View {

    public let corners: [SIMD2<Double>]
    public let imageSize: CGSize
    public let columns: Int
    public let rows: Int
    public var colour: Color

    public init(corners: [SIMD2<Double>],
                imageSize: CGSize,
                columns: Int,
                rows: Int,
                colour: Color = .green) {
        self.corners = corners
        self.imageSize = imageSize
        self.columns = columns
        self.rows = rows
        self.colour = colour
    }

    public var body: some View {
        GeometryReader { geometry in
            let mapping = AspectFitMapping(imageSize: imageSize,
                                           viewSize: geometry.size)

            if corners.count == columns * rows {
                // Grid lines first, so the corner dots sit on top of them.
                Path { path in
                    for row in 0..<rows {
                        for column in 0..<(columns - 1) {
                            let a = mapping.viewPoint(fromImage: corners[row * columns + column])
                            let b = mapping.viewPoint(fromImage: corners[row * columns + column + 1])
                            path.move(to: a)
                            path.addLine(to: b)
                        }
                    }
                    for column in 0..<columns {
                        for row in 0..<(rows - 1) {
                            let a = mapping.viewPoint(fromImage: corners[row * columns + column])
                            let b = mapping.viewPoint(fromImage: corners[(row + 1) * columns + column])
                            path.move(to: a)
                            path.addLine(to: b)
                        }
                    }
                }
                .stroke(colour.opacity(0.7), lineWidth: 1)
            }

            ForEach(Array(corners.enumerated()), id: \.offset) { _, corner in
                Circle()
                    .fill(colour)
                    .frame(width: 4, height: 4)
                    .position(mapping.viewPoint(fromImage: corner))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Nine-cell heat map of where the board has been seen.
///
/// Shown rather than a bare view count because the two are not
/// interchangeable: sixteen views all taken in the centre of the frame
/// produce a calibration that fits the middle and extrapolates the corners,
/// and the corners are where the athlete actually is during approach and
/// landing.
public struct CoverageGridView: View {

    public let coverage: CoverageGrid

    public init(coverage: CoverageGrid) {
        self.coverage = coverage
    }

    public var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<CoverageGrid.rows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<CoverageGrid.columns, id: \.self) { column in
                        Rectangle()
                            .fill(fill(count: coverage[column, row]))
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
        .padding(4)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func fill(count: Int) -> Color {
        switch count {
        case 0:  return .white.opacity(0.15)
        case 1:  return .green.opacity(0.45)
        default: return .green.opacity(0.85)
        }
    }
}

/// Pose skeleton drawn over a video frame.
///
/// The event correction screen exists so a human can judge whether a foot is
/// on the ground at a given frame. Doing that from raw video at 120–240 fps is
/// genuinely hard — the foot is small, often motion-blurred, and frequently
/// against a similarly-coloured runway. Drawing what the tracker believes
/// turns the judgement from "where is the foot" into "does the tracker agree
/// with me", which is both easier and the actual question.
public struct SkeletonOverlay: View {

    public let frame: PoseFrame?
    public let imageSize: CGSize
    /// Highlighted foot, drawn heavier. Set to the side of the event being
    /// reviewed so the relevant limb stands out.
    public var emphasisSide: GroundEvent.Side?
    public var minimumConfidence: Double

    public init(frame: PoseFrame?,
                imageSize: CGSize,
                emphasisSide: GroundEvent.Side? = nil,
                minimumConfidence: Double = 0.35) {
        self.frame = frame
        self.imageSize = imageSize
        self.emphasisSide = emphasisSide
        self.minimumConfidence = minimumConfidence
    }

    public var body: some View {
        GeometryReader { geometry in
            if let frame {
                let mapping = AspectFitMapping(imageSize: imageSize,
                                               viewSize: geometry.size)

                ForEach(Array(PoseLandmark.connections.enumerated()), id: \.offset) { _, pair in
                    if let a = point(pair.0, mapping: mapping),
                       let b = point(pair.1, mapping: mapping) {
                        Path { path in
                            path.move(to: a)
                            path.addLine(to: b)
                        }
                        .stroke(colour(for: pair.0),
                                lineWidth: isEmphasised(pair.0) ? 3 : 1.5)
                    }
                }

                ForEach(PoseLandmark.analysed, id: \.rawValue) { landmark in
                    if let position = point(landmark, mapping: mapping) {
                        Circle()
                            .fill(colour(for: landmark))
                            .frame(width: isEmphasised(landmark) ? 8 : 5,
                                   height: isEmphasised(landmark) ? 8 : 5)
                            .position(position)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ landmark: PoseLandmark,
                       mapping: AspectFitMapping) -> CGPoint? {
        guard let keypoint = frame?[landmark],
              keypoint.confidence >= minimumConfidence else { return nil }
        return mapping.viewPoint(fromImage: keypoint.position)
    }

    private func isEmphasised(_ landmark: PoseLandmark) -> Bool {
        guard let emphasisSide else { return false }
        let isFoot: Set<PoseLandmark> = emphasisSide == .left
            ? [.leftAnkle, .leftHeel, .leftFootIndex, .leftKnee]
            : [.rightAnkle, .rightHeel, .rightFootIndex, .rightKnee]
        return isFoot.contains(landmark)
    }

    private func colour(for landmark: PoseLandmark) -> Color {
        if isEmphasised(landmark) { return .yellow }
        return landmark.isLeft ? .cyan : .orange
    }
}
