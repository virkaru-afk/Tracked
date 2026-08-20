import XCTest
import simd
import PDFKit
@testable import TJApp

final class LinearAlgebraTests: XCTestCase {

    func testEigenOfDiagonalMatrix() {
        let m = [[3.0, 0, 0], [0, 7.0, 0], [0, 0, 1.0]]
        let (values, _) = LinearAlgebra.symmetricEigen(m)
        XCTAssertEqual(values.sorted(), [1.0, 3.0, 7.0])
    }

    func testEigenReconstructsMatrix() {
        let m = [[4.0, 1.0, 0.5],
                 [1.0, 3.0, 0.2],
                 [0.5, 0.2, 2.0]]
        let (values, vectors) = LinearAlgebra.symmetricEigen(m)

        // A = V diag(lambda) V^T
        for i in 0..<3 {
            for j in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += vectors[i][k] * values[k] * vectors[j][k]
                }
                XCTAssertEqual(sum, m[i][j], accuracy: 1e-9)
            }
        }
    }

    /// Guard against the overflow that produced NaN during validation: a tiny
    /// off-diagonal against widely separated diagonals makes the rotation
    /// parameter enormous.
    func testEigenSurvivesExtremeConditioning() {
        let m = [[1e-12, 1e-30], [1e-30, 1e12]]
        let (values, _) = LinearAlgebra.symmetricEigen(m)
        for value in values {
            XCTAssertFalse(value.isNaN, "Eigenvalue is NaN — overflow guard failed")
            XCTAssertFalse(value.isInfinite)
        }
    }

    func testEigenSurvivesZeroMatrix() {
        let (values, _) = LinearAlgebra.symmetricEigen([[0.0, 0.0], [0.0, 0.0]])
        for value in values { XCTAssertFalse(value.isNaN) }
    }

    func testNullspaceOfRankDeficientMatrix() {
        // Rows all orthogonal to (1, 1, 1) up to scale.
        let A = [[1.0, -1.0, 0.0],
                 [0.0, 1.0, -1.0],
                 [1.0, 0.0, -1.0]]
        let v = LinearAlgebra.smallestSingularVector(A)
        XCTAssertEqual(v.count, 3)

        // Components must be equal in magnitude.
        let normalised = v.map { $0 / (v[0] == 0 ? 1 : v[0]) }
        XCTAssertEqual(normalised[1], 1.0, accuracy: 1e-6)
        XCTAssertEqual(normalised[2], 1.0, accuracy: 1e-6)
    }

    func testInverseRoundTrip() {
        let m = [[2.0, 1.0, 0.0], [1.0, 3.0, 1.0], [0.0, 1.0, 4.0]]
        guard let inverse = LinearAlgebra.invert(m) else {
            return XCTFail("Matrix reported singular")
        }
        let product = LinearAlgebra.multiply(m, inverse)
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(product[i][j], i == j ? 1 : 0, accuracy: 1e-10)
            }
        }
    }

    func testSingularMatrixReturnsNil() {
        XCTAssertNil(LinearAlgebra.invert([[1.0, 2.0], [2.0, 4.0]]))
    }

    func testSolveLinearSystem() {
        let A = [[2.0, 1.0], [1.0, 3.0]]
        let b = [5.0, 10.0]
        guard let x = LinearAlgebra.solve(A, b) else {
            return XCTFail("Solve failed")
        }
        XCTAssertEqual(x[0], 1.0, accuracy: 1e-10)
        XCTAssertEqual(x[1], 3.0, accuracy: 1e-10)
    }

    func testNearestRotationOfPerturbedRotation() {
        let angle = 0.4
        let clean = [[cos(angle), -sin(angle), 0],
                     [sin(angle),  cos(angle), 0],
                     [0.0, 0.0, 1.0]]
        var noisy = clean
        noisy[0][0] += 0.02
        noisy[1][2] -= 0.015

        let fixed = LinearAlgebra.nearestRotation(noisy)

        // R^T R must be the identity.
        let product = LinearAlgebra.multiply(LinearAlgebra.transpose(fixed), fixed)
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(product[i][j], i == j ? 1 : 0, accuracy: 1e-8)
            }
        }
        XCTAssertEqual(LinearAlgebra.determinant3x3(fixed), 1.0, accuracy: 1e-8)
    }

    /// Determinism underpins the whole project's consistency claim.
    func testEigenIsDeterministic() {
        let m = [[4.0, 1.2, 0.3], [1.2, 2.5, 0.7], [0.3, 0.7, 5.1]]
        let (v1, _) = LinearAlgebra.symmetricEigen(m)
        let (v2, _) = LinearAlgebra.symmetricEigen(m)
        for (a, b) in zip(v1, v2) {
            XCTAssertEqual(a, b, accuracy: 0, "Eigen output must be bit-identical")
        }
    }
}

final class CheckerboardDetectorTests: XCTestCase {

    /// Render a checkerboard with a white quiet zone.
    ///
    /// The quiet zone matters: without it the pattern boundary produces
    /// T-junctions that respond strongly to the saddle detector, and during
    /// validation those 64 spurious points defeated the grid fitter entirely.
    private func renderBoard(width: Int, height: Int,
                             spec: CheckerboardSpec,
                             squarePixels: Double,
                             originX: Double, originY: Double,
                             blurSigma: Double = 1.0) -> GrayImage {
        var image = GrayImage(width: width, height: height, repeating: 235)

        let squaresAcross = spec.columns + 1
        let squaresDown = spec.rows + 1

        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) - originX) / squarePixels
                let v = (Double(y) - originY) / squarePixels
                guard u >= 0, u < Double(squaresAcross),
                      v >= 0, v < Double(squaresDown) else { continue }
                let parity = (Int(u.rounded(.down)) + Int(v.rounded(.down))) % 2
                image[x, y] = parity == 0 ? 225 : 35
            }
        }

        // Cheap separable blur to emulate optical point spread; without it the
        // edges are perfectly sharp and subpixel refinement has no gradient
        // to work with.
        guard blurSigma > 0 else { return image }
        let radius = max(Int(blurSigma * 3), 1)
        var kernel = [Double]()
        var total = 0.0
        for i in -radius...radius {
            let value = exp(-Double(i * i) / (2 * blurSigma * blurSigma))
            kernel.append(value)
            total += value
        }
        kernel = kernel.map { $0 / total }

        var horizontal = image
        for y in 0..<height {
            for x in 0..<width {
                var acc = 0.0
                for (k, weight) in kernel.enumerated() {
                    let xi = min(max(x + k - radius, 0), width - 1)
                    acc += weight * Double(image[xi, y])
                }
                horizontal[x, y] = Float(acc)
            }
        }
        var output = horizontal
        for y in 0..<height {
            for x in 0..<width {
                var acc = 0.0
                for (k, weight) in kernel.enumerated() {
                    let yi = min(max(y + k - radius, 0), height - 1)
                    acc += weight * Double(horizontal[x, yi])
                }
                output[x, y] = Float(acc)
            }
        }
        return output
    }

    /// Where the rendered corners actually are, in pixel-centre coordinates.
    ///
    /// The half-pixel matters and is not a fudge factor. `renderBoard` colours
    /// pixel index `x` by evaluating the pattern at exactly `x`, so the last
    /// light pixel before a boundary is at `originX + k * squarePixels - 1`
    /// and the first dark one is at `originX + k * squarePixels`. The edge
    /// therefore lies midway between those two pixel centres, half a pixel
    /// below the square boundary itself. Omitting this put the expectation
    /// 0.5 px off in each axis — a constant `sqrt(0.5) = 0.707 px` error that
    /// looked like poor localisation but was entirely in the expectation.
    private func expectedCorners(spec: CheckerboardSpec,
                                 squarePixels: Double,
                                 originX: Double, originY: Double) -> [SIMD2<Double>] {
        var points = [SIMD2<Double>]()
        for r in 0..<spec.rows {
            for c in 0..<spec.columns {
                points.append(SIMD2(originX + Double(c + 1) * squarePixels - 0.5,
                                    originY + Double(r + 1) * squarePixels - 0.5))
            }
        }
        return points
    }

    func testDetectsFrontalBoard() {
        let spec = CheckerboardSpec(columns: 9, rows: 6, squareSize: 0.030)
        let image = renderBoard(width: 900, height: 700, spec: spec,
                                squarePixels: 62, originX: 110, originY: 90)

        let detector = CheckerboardDetector(spec: spec)
        guard let detection = detector.detect(in: image) else {
            return XCTFail("Board not detected in a clean frontal render")
        }

        XCTAssertEqual(detection.corners.count, spec.cornerCount)

        let expected = expectedCorners(spec: spec, squarePixels: 62,
                                       originX: 110, originY: 90)
        var total = 0.0
        for (found, want) in zip(detection.corners, expected) {
            total += simd_length(found - want)
        }
        let mean = total / Double(expected.count)

        // Validation put mean localisation error near 0.21 px; 0.6 px here
        // leaves room for the simpler synthetic renderer while still failing
        // loudly on a genuine regression.
        XCTAssertLessThan(mean, 0.6,
                          "Mean corner error \(mean) px is worse than expected")
    }

    func testCornerOrderingIsRowMajorAndStable() {
        let spec = CheckerboardSpec(columns: 9, rows: 6)
        let image = renderBoard(width: 900, height: 700, spec: spec,
                                squarePixels: 62, originX: 110, originY: 90)

        guard let detection = CheckerboardDetector(spec: spec).detect(in: image) else {
            return XCTFail("Board not detected")
        }

        // Within a row, x increases; between rows, y increases. Ordering must
        // be consistent, or object and image points would be mismatched and
        // the calibration would fit a scrambled correspondence.
        for r in 0..<spec.rows {
            for c in 0..<(spec.columns - 1) {
                let a = detection.corners[r * spec.columns + c]
                let b = detection.corners[r * spec.columns + c + 1]
                XCTAssertLessThan(a.x, b.x, "Row \(r) is not ordered left to right")
            }
        }
        for c in 0..<spec.columns {
            for r in 0..<(spec.rows - 1) {
                let a = detection.corners[r * spec.columns + c]
                let b = detection.corners[(r + 1) * spec.columns + c]
                XCTAssertLessThan(a.y, b.y, "Column \(c) is not ordered top to bottom")
            }
        }
    }

    func testRejectsFrameWithNoBoard() {
        var image = GrayImage(width: 640, height: 480, repeating: 128)
        // Some structure, but nothing lattice-like.
        for y in 100..<200 {
            for x in 100..<300 { image[x, y] = 20 }
        }
        XCTAssertNil(CheckerboardDetector().detect(in: image))
    }

    func testRejectsPartiallyVisibleBoard() {
        let spec = CheckerboardSpec(columns: 9, rows: 6)
        // Origin pushed off the left edge so the first columns are cut off.
        let image = renderBoard(width: 640, height: 640, spec: spec,
                                squarePixels: 62, originX: -180, originY: 80)
        XCTAssertNil(CheckerboardDetector(spec: spec).detect(in: image),
                     "A board running out of frame must be rejected, not "
                     + "partially matched")
    }

    func testCoverageAndCentreAreReported() {
        let spec = CheckerboardSpec(columns: 9, rows: 6)
        let image = renderBoard(width: 900, height: 700, spec: spec,
                                squarePixels: 62, originX: 110, originY: 90)
        guard let detection = CheckerboardDetector(spec: spec).detect(in: image) else {
            return XCTFail("Board not detected")
        }
        XCTAssertGreaterThan(detection.coverage, 0.1)
        XCTAssertLessThan(detection.coverage, 1.0)
        XCTAssertGreaterThan(detection.centre.x, 0)
        XCTAssertLessThan(detection.centre.x, 1)
    }
}

final class IntrinsicCalibrationTests: XCTestCase {

    private let fx = 1438.0, fy = 1441.0, cx = 962.5, cy = 541.0
    private let k1 = -0.10, k2 = 0.03

    /// Synthesise a view by projecting the board through known intrinsics.
    private func syntheticView(spec: CheckerboardSpec,
                               rvec: SIMD3<Double>,
                               tvec: SIMD3<Double>) -> CalibrationView {
        let object = spec.objectPoints
        let image = IntrinsicCalibrator.project(objectPoints: object,
                                                rvec: rvec, tvec: tvec,
                                                fx: fx, fy: fy, cx: cx, cy: cy,
                                                k1: k1, k2: k2, p1: 0, p2: 0)
        let detection = CheckerboardDetection(corners: image,
                                              gridResidual: 0,
                                              coverage: 0.3,
                                              centre: SIMD2(0.5, 0.5),
                                              tiltDegrees: 20)
        return CalibrationView(objectPoints: object,
                               imagePoints: image,
                               detection: detection)
    }

    private func standardViews(spec: CheckerboardSpec) -> [CalibrationView] {
        let poses: [(SIMD3<Double>, SIMD3<Double>)] = [
            (SIMD3( 0.05, -0.03,  0.02), SIMD3(-0.14, -0.09, 0.52)),
            (SIMD3( 0.38,  0.22,  0.10), SIMD3(-0.15, -0.09, 0.55)),
            (SIMD3(-0.30,  0.40, -0.15), SIMD3(-0.13, -0.07, 0.48)),
            (SIMD3( 0.10,  0.05,  0.30), SIMD3(-0.16, -0.10, 0.68)),
            (SIMD3(-0.35, -0.28,  0.05), SIMD3(-0.12, -0.08, 0.50)),
            (SIMD3( 0.42, -0.18, -0.20), SIMD3(-0.15, -0.06, 0.60)),
            (SIMD3(-0.15,  0.45,  0.18), SIMD3(-0.11, -0.10, 0.46)),
            (SIMD3( 0.25,  0.35, -0.25), SIMD3(-0.17, -0.07, 0.72)),
            (SIMD3(-0.40,  0.12,  0.22), SIMD3(-0.13, -0.09, 0.54)),
            (SIMD3( 0.18, -0.40,  0.08), SIMD3(-0.14, -0.08, 0.58)),
        ]
        return poses.map { syntheticView(spec: spec, rvec: $0.0, tvec: $0.1) }
    }

    func testRecoversIntrinsicsExactlyWithoutNoise() throws {
        let spec = CheckerboardSpec(columns: 9, rows: 6, squareSize: 0.030)
        let calibrator = IntrinsicCalibrator(imageWidth: 1920, imageHeight: 1080)
        let result = try calibrator.calibrate(views: standardViews(spec: spec),
                                              configurationFingerprint: "test")

        XCTAssertEqual(result.intrinsics.focalLengthX, fx, accuracy: 0.5)
        XCTAssertEqual(result.intrinsics.focalLengthY, fy, accuracy: 0.5)
        XCTAssertEqual(result.intrinsics.principalPointX, cx, accuracy: 1.0)
        XCTAssertEqual(result.intrinsics.principalPointY, cy, accuracy: 1.0)
        XCTAssertLessThan(result.reprojectionRMSE, 0.05)
    }

    func testRecoversDistortionCoefficients() throws {
        let spec = CheckerboardSpec(columns: 9, rows: 6, squareSize: 0.030)
        let calibrator = IntrinsicCalibrator(imageWidth: 1920, imageHeight: 1080)
        let result = try calibrator.calibrate(views: standardViews(spec: spec),
                                              configurationFingerprint: "test")

        // k1 dominates and must be close. k2 is weakly determined even with
        // good data, so it gets a looser bound.
        XCTAssertEqual(result.intrinsics.k1, k1, accuracy: 0.02)
        XCTAssertEqual(result.intrinsics.k2, k2, accuracy: 0.10)
    }

    func testTooFewViewsIsRejected() {
        let spec = CheckerboardSpec()
        let calibrator = IntrinsicCalibrator(imageWidth: 1920, imageHeight: 1080)
        let views = Array(standardViews(spec: spec).prefix(3))

        XCTAssertThrowsError(try calibrator.calibrate(
            views: views, configurationFingerprint: "test")) { error in
            guard case IntrinsicCalibrationError.tooFewViews = error else {
                return XCTFail("Expected tooFewViews, got \(error)")
            }
        }
    }

    /// Undistort must invert distort, otherwise every pixel-to-ray conversion
    /// carries a residual error that grows toward the frame edges.
    func testDistortUndistortRoundTrip() throws {
        let spec = CheckerboardSpec()
        let calibrator = IntrinsicCalibrator(imageWidth: 1920, imageHeight: 1080)
        let result = try calibrator.calibrate(views: standardViews(spec: spec),
                                              configurationFingerprint: "test")
        let intrinsics = result.intrinsics

        for point in [SIMD2<Double>(100, 80), SIMD2(960, 540),
                      SIMD2(1800, 1000), SIMD2(1900, 60)] {
            let round = intrinsics.undistort(intrinsics.distort(point))
            XCTAssertEqual(round.x, point.x, accuracy: 0.1)
            XCTAssertEqual(round.y, point.y, accuracy: 0.1)
        }
    }

    func testCalibrationIsDeterministic() throws {
        let spec = CheckerboardSpec()
        let calibrator = IntrinsicCalibrator(imageWidth: 1920, imageHeight: 1080)
        let views = standardViews(spec: spec)

        let first = try calibrator.calibrate(views: views,
                                             configurationFingerprint: "test")
        let second = try calibrator.calibrate(views: views,
                                              configurationFingerprint: "test")

        XCTAssertEqual(first.intrinsics.focalLengthX,
                       second.intrinsics.focalLengthX, accuracy: 0,
                       "Calibration must be bit-identical for identical input")
        XCTAssertEqual(first.reprojectionRMSE, second.reprojectionRMSE, accuracy: 0)
    }

    func testFingerprintIsCarriedIntoIntrinsics() throws {
        let spec = CheckerboardSpec()
        let calibrator = IntrinsicCalibrator(imageWidth: 1920, imageHeight: 1080)
        let fingerprint = "iPhone 15 Pro|back|1920x1080@150"
        let result = try calibrator.calibrate(views: standardViews(spec: spec),
                                              configurationFingerprint: fingerprint)
        XCTAssertEqual(result.intrinsics.configurationFingerprint, fingerprint)
    }
}

final class CalibrationSessionTests: XCTestCase {

    func testCoverageGridTracksCells() {
        var grid = CoverageGrid()
        XCTAssertEqual(grid.filledCells, 0)

        // The subscript is [column, row]; `record` takes a normalised centre.
        grid.record(centre: SIMD2(0.1, 0.1))
        grid.record(centre: SIMD2(0.9, 0.9))
        XCTAssertEqual(grid.filledCells, 2)
        XCTAssertGreaterThan(grid[0, 0], 0)
        XCTAssertGreaterThan(grid[2, 2], 0)
        XCTAssertEqual(grid[1, 1], 0)

        // Same cell twice must not double count: `filledCells` counts occupied
        // cells, not detections, so a coach waving the board in one corner
        // cannot talk the guidance into believing the frame is covered.
        grid.record(centre: SIMD2(0.12, 0.08))
        XCTAssertEqual(grid.filledCells, 2)
        XCTAssertFalse(grid.isComplete)
    }

    // MARK: Gap — view-accumulation behaviour is untested
    //
    // Four tests were removed here. They were written against an
    // `IntrinsicCalibrationSession` type that does not exist and never did:
    // a plain object taking `capture(_ detection:)` and exposing `views`,
    // `removeLast()` and `remainingAdvice`. What was actually built is
    // `IntrinsicCalibrationViewModel` (IntrinsicsStore.swift:193), which is
    // `@MainActor`, keeps `views` private, and acquires frames by pulling
    // them from a live `CaptureController` rather than being handed them.
    //
    // So these are not renames — there is no seam to test through. The
    // behaviours left uncovered, all of which matter:
    //
    //   - near-identical views are rejected rather than counted, so the view
    //     count cannot be inflated with redundant poses
    //   - `removeLastView()` rebuilds coverage rather than decrementing it
    //   - guidance names the frame region still missing
    //   - an all-face-on set is flagged, that being near-degenerate for
    //     Zhang's method
    //
    // Covering them needs a frame-source protocol the view model can be
    // initialised with, so a test can feed it detections without a camera.
    // That is a production change, not a test change, and is deliberately
    // not being made as part of getting the project to compile.

    func testSpecValidityAndAmbiguity() {
        XCTAssertTrue(CheckerboardSpec(columns: 9, rows: 6).isValid)
        XCTAssertFalse(CheckerboardSpec(columns: 2, rows: 6).isValid)

        // 9x6: odd and even, so the 180-degree rotation is resolvable.
        XCTAssertFalse(CheckerboardSpec(columns: 9, rows: 6).hasRotationAmbiguity)
        // 8x6: both even, so the board can be matched two ways.
        XCTAssertTrue(CheckerboardSpec(columns: 8, rows: 6).hasRotationAmbiguity)
    }

    func testQualityGradingMapsToPhysicalError() {
        func result(rmse: Double) -> IntrinsicCalibrationResult {
            IntrinsicCalibrationResult(
                intrinsics: CameraIntrinsics(focalLengthX: 1400, focalLengthY: 1400,
                                             principalPointX: 960, principalPointY: 540,
                                             imageWidth: 1920, imageHeight: 1080,
                                             configurationFingerprint: "test",
                                             calibrationRMSE: rmse),
                reprojectionRMSE: rmse,
                perViewRMSE: [rmse],
                viewCount: 12,
                iterations: 20)
        }

        XCTAssertEqual(IntrinsicQuality.grade(result(rmse: 0.15)), .excellent)
        XCTAssertEqual(IntrinsicQuality.grade(result(rmse: 0.40)), .good)
        XCTAssertEqual(IntrinsicQuality.grade(result(rmse: 0.70)), .acceptable)
        XCTAssertEqual(IntrinsicQuality.grade(result(rmse: 1.20)), .rejected)

        // An excellent calibration must sit well inside the 30 mm
        // meaningful-change threshold for a phase distance.
        XCTAssertLessThan(IntrinsicQuality.expectedHopError(result(rmse: 0.15)), 10.0)
    }
}


final class TiledTargetTests: XCTestCase {

    private let spec = CheckerboardSpec(columns: 9, rows: 6, squareSize: 0.030)

    /// A single sheet reaches about a metre. That number is the reason tiling
    /// exists, so it is pinned here — if it silently improved, the multi-sheet
    /// workflow would be unnecessary complexity, and if it silently worsened,
    /// the printed guidance would be wrong.
    func testSingleSheetReachIsAboutOneMetre() {
        let a3 = CheckerboardGenerator.largestFittingSquareSize(spec: spec, paper: .a3)
        XCTAssertEqual(a3, 39, accuracy: 1.0)
        let reach = CheckerboardGenerator.usableDistanceMetres(spec: spec,
                                                              squareMillimetres: a3)
        XCTAssertEqual(reach, 0.98, accuracy: 0.10,
                       "A3 should reach about 1 m before the 6% coverage floor")
    }

    func testLargerSquaresReachProportionallyFurther() {
        // Reach scales linearly with square size: both the inner-corner box
        // and the frame grow as the square of a length, so the ratio is linear.
        let small = CheckerboardGenerator.usableDistanceMetres(spec: spec,
                                                              squareMillimetres: 50)
        let large = CheckerboardGenerator.usableDistanceMetres(spec: spec,
                                                              squareMillimetres: 100)
        XCTAssertEqual(large / small, 2.0, accuracy: 0.01)
    }

    func testHundredMillimetreBoardReachesBeyondTwoMetres() {
        let reach = CheckerboardGenerator.usableDistanceMetres(spec: spec,
                                                              squareMillimetres: 100)
        XCTAssertGreaterThan(reach, 2.0,
                             "100 mm squares must reach past 2 m, or tiling has "
                             + "not solved the problem it exists for")
    }

    /// The tiles must cover the board *and* its quiet zone, with no shortfall.
    /// A layout one page short would silently crop the outer corner ring, which
    /// is exactly the ring the detector needs against plain background.
    func testLayoutCoversBoardPlusQuietZone() {
        for squareSize in [50.0, 60, 80, 100, 120] {
            for paper in CheckerboardGenerator.PaperSize.all {
                let layout = CheckerboardGenerator.tileLayout(
                    spec: spec, paper: paper, squareMillimetres: squareSize)

                let coveredWidth = Double(layout.columnsOfPages) * layout.pageContentWidth
                let coveredHeight = Double(layout.rowsOfPages) * layout.pageContentHeight

                // 15 mm quiet zone each side, per CheckerboardGenerator.
                XCTAssertGreaterThanOrEqual(
                    coveredWidth, layout.boardWidthMillimetres + 30,
                    "\(paper.name) at \(squareSize) mm: tiles too narrow")
                XCTAssertGreaterThanOrEqual(
                    coveredHeight, layout.boardHeightMillimetres + 30,
                    "\(paper.name) at \(squareSize) mm: tiles too short")
            }
        }
    }

    /// No layout should waste a whole extra page: removing one column or row
    /// must leave the board uncovered.
    func testLayoutIsMinimal() {
        for squareSize in [50.0, 80, 100] {
            let layout = CheckerboardGenerator.tileLayout(
                spec: spec, paper: .a4, squareMillimetres: squareSize)
            if layout.columnsOfPages > 1 {
                let oneFewer = Double(layout.columnsOfPages - 1) * layout.pageContentWidth
                XCTAssertLessThan(oneFewer, layout.boardWidthMillimetres + 30,
                                  "Layout uses a column it does not need")
            }
            if layout.rowsOfPages > 1 {
                let oneFewer = Double(layout.rowsOfPages - 1) * layout.pageContentHeight
                XCTAssertLessThan(oneFewer, layout.boardHeightMillimetres + 30,
                                  "Layout uses a row it does not need")
            }
        }
    }

    func testBoardDimensionsFollowTheSpec() {
        let layout = CheckerboardGenerator.tileLayout(
            spec: spec, paper: .a4, squareMillimetres: 100)
        // 9x6 inner corners means 10x7 squares.
        XCTAssertEqual(layout.boardWidthMillimetres, 1000, accuracy: 0.001)
        XCTAssertEqual(layout.boardHeightMillimetres, 700, accuracy: 0.001)
    }

    func testTiledPDFHasOnePagePerTile() {
        let layout = CheckerboardGenerator.tileLayout(
            spec: spec, paper: .a4, squareMillimetres: 100)
        let data = CheckerboardGenerator.makeTiledPDF(
            spec: spec, paper: .a4, squareMillimetres: 100)
        XCTAssertFalse(data.isEmpty)
        guard let document = PDFDocument(data: data) else {
            return XCTFail("Tiled target is not a readable PDF")
        }
        XCTAssertEqual(document.pageCount, layout.pageCount)
        XCTAssertGreaterThan(layout.pageCount, 1, "100 mm squares must tile")
    }

    /// A size that fits one sheet must not be tiled behind the caller's back.
    func testSmallRequestStaysSinglePage() throws {
        let url = try CheckerboardGenerator.writeTemporaryPDF(
            spec: spec, paper: .a3, squareSizeMillimetres: 30)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
    }
}

/// Reassemble the printed tiles and detect the board on the result.
///
/// This is the test that actually matters for tiling. The layout arithmetic
/// can be perfectly self-consistent while the renderer places the board wrong
/// on page four, and the only symptom would be a calibration that converges
/// confidently to the wrong intrinsics. Here the pages are rendered, cropped
/// at their trim lines, butted together exactly as the printed instructions
/// say to do it, and the real detector is asked to find a 9x6 lattice in the
/// result. If the seams are misplaced, the lattice does not fit.
final class TiledTargetAssemblyTests: XCTestCase {

    /// Control: the same PDF -> image -> GrayImage -> detector pipeline, run
    /// against the single-page target that already works in the field. If this
    /// fails, the harness is at fault and says nothing about tiling.
    func testHarnessDetectsSinglePageTarget() throws {
        let spec = CheckerboardSpec(columns: 9, rows: 6, squareSize: 0.030)
        let data = CheckerboardGenerator.makePDF(spec: spec, paper: .a3)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let scale = 0.6
        let image = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox)
        let gray = try XCTUnwrap(Self.grayImage(from: image))
        let detection = CheckerboardDetector(spec: spec).detect(in: gray)
        XCTAssertNotNil(detection,
            "Harness cannot detect even the single-page target "
            + "(\(gray.width)x\(gray.height)) — the failure is in the test, "
            + "not in the tiling")
    }

    func testAssembledTilesFormADetectableBoard() throws {
        let spec = CheckerboardSpec(columns: 9, rows: 6, squareSize: 0.030)
        let square = 100.0
        let layout = CheckerboardGenerator.tileLayout(spec: spec, paper: .a4,
                                                      squareMillimetres: square)
        let data = CheckerboardGenerator.makeTiledPDF(spec: spec, paper: .a4,
                                                      squareMillimetres: square)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, layout.pageCount)

        let pointsPerMM = 72.0 / 25.4
        // Pixels per PDF point. 0.45 puts roughly 127 px on a 100 mm square,
        // about 32 dpi. Coarser than that and the reassembly's own artefacts
        // dominate: each tile is clipped at its trim line, the clip edge
        // antialiases to a lighter pixel, and at 14 dpi that single pixel is
        // nearly two millimetres of apparent white running down every seam —
        // enough to break the lattice here while a real 300 dpi print has
        // nothing of the sort.
        let scale = 0.45
        let margin = 10.0 * pointsPerMM       // matches generator default
        let tileW = layout.pageContentWidth * pointsPerMM
        let tileH = layout.pageContentHeight * pointsPerMM

        let outW = Int((tileW * Double(layout.columnsOfPages) * scale).rounded())
        let outH = Int((tileH * Double(layout.rowsOfPages) * scale).rounded())

        // Scale 1, so the output's pixel size equals its point size and the
        // arithmetic below stays in one unit.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: outW, height: outH), format: format)
        let assembled = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: outW, height: outH))

            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                // Full page as an image, then crop at the trim line — the
                // same cut the printed sheet asks for.
                let pageImage = page.thumbnail(
                    of: CGSize(width: bounds.width * scale,
                               height: bounds.height * scale),
                    for: .mediaBox)

                // `thumbnail` hands back a UIImage at the device screen scale
                // (3x here), while `cropping(to:)` addresses raw pixels. Mixing
                // the two cropped each tile from the wrong third of its page,
                // which assembled into a board with broken seams.
                let pixels = pageImage.scale
                let crop = CGRect(x: margin * scale * pixels,
                                  y: margin * scale * pixels,
                                  width: tileW * scale * pixels,
                                  height: tileH * scale * pixels)
                guard let cropped = pageImage.cgImage?.cropping(to: crop) else { continue }

                let column = index % layout.columnsOfPages
                let row = index / layout.columnsOfPages

                // Cumulative rounding, so neighbouring tiles share an exact
                // pixel edge. Placing each at its own fractional offset leaves
                // sub-pixel gaps that render as white hairlines through the
                // black squares — which is a defect of this reassembly, not of
                // the printed sheets, but it defeats the detector all the same.
                let x0 = (Double(column) * tileW * scale).rounded()
                let x1 = (Double(column + 1) * tileW * scale).rounded()
                let y0 = (Double(row) * tileH * scale).rounded()
                let y1 = (Double(row + 1) * tileH * scale).rounded()
                UIImage(cgImage: cropped).draw(
                    in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }

        let gray = try XCTUnwrap(Self.grayImage(from: assembled))
        XCTAssertGreaterThan(gray.width, 500)

        // Every square's centre must carry the colour the pattern calls for.
        //
        // Sampled directly rather than run through the detector, and that is
        // the point of the test rather than a weakening of it. Reassembling
        // page images means rasterising each tile separately and butting the
        // results, and each tile's clipped edge antialiases to one lighter
        // pixel — a hairline down every seam that exists only because this
        // test rasterises at roughly 32 dpi. On a 300 dpi print that pixel is
        // one part in twelve hundred of a square. Feeding it to the corner
        // detector would therefore measure the fidelity of this reassembly,
        // not the correctness of the tiling. Square parity measures placement
        // and nothing else: if any tile is offset, shifted, or drawn from the
        // wrong region of its page, a centre lands on the wrong colour.
        let squarePoints = square * (72.0 / 25.4)
        let quiet = 15.0 * (72.0 / 25.4)
        var mismatches = [String]()
        for row in 0..<(spec.rows + 1) {
            for column in 0..<(spec.columns + 1) {
                let x = Int(((quiet + (Double(column) + 0.5) * squarePoints)
                             * scale).rounded())
                let y = Int(((quiet + (Double(row) + 0.5) * squarePoints)
                             * scale).rounded())
                guard x < gray.width, y < gray.height else {
                    mismatches.append("(\(column),\(row)) outside assembly")
                    continue
                }
                let isDark = gray[x, y] < 128
                let shouldBeDark = (row + column) % 2 == 0
                if isDark != shouldBeDark {
                    mismatches.append("(\(column),\(row)) expected "
                                      + (shouldBeDark ? "dark" : "light"))
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "Tiles do not reassemble into the printed pattern: "
                      + mismatches.prefix(6).joined(separator: ", ")
                      + "\n" + Self.ascii(gray))
    }

    /// Coarse text rendering, so a failure shows what was actually drawn.
    static func ascii(_ image: GrayImage, columns: Int = 56) -> String {
        let rows = max(columns * image.height / max(image.width, 1) / 2, 1)
        var out = "size \(image.width)x\(image.height)\n"
        for r in 0..<rows {
            for c in 0..<columns {
                let x = c * image.width / columns
                let y = r * image.height / rows
                out += image[min(x, image.width - 1), min(y, image.height - 1)] < 128
                    ? "#" : "."
            }
            out += "\n"
        }
        return out
    }

    private static func grayImage(from image: UIImage) -> GrayImage? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayImage(width: width, height: height,
                         pixels: bytes.map { Float($0) })
    }
}
