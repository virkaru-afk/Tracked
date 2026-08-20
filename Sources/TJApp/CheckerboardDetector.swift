import Foundation
import CoreVideo
import CoreImage
import simd

/// A grayscale image as a flat Float buffer.
///
/// Float rather than UInt8 because every stage downstream works in
/// derivatives and subpixel interpolation, and converting once at the
/// boundary is cheaper and less error-prone than converting repeatedly.
public struct GrayImage {

    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, repeating value: Float = 0) {
        self.width = width
        self.height = height
        self.pixels = [Float](repeating: value, count: width * height)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    @inline(__always)
    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Bilinear sample. Returns nil outside the valid interpolation region.
    @inline(__always)
    public func sample(x: Double, y: Double) -> Double? {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return nil }
        let ax = x - Double(x0), ay = y - Double(y0)
        let p00 = Double(self[x0, y0]),     p10 = Double(self[x0 + 1, y0])
        let p01 = Double(self[x0, y0 + 1]), p11 = Double(self[x0 + 1, y0 + 1])
        return p00 * (1 - ax) * (1 - ay) + p10 * ax * (1 - ay)
             + p01 * (1 - ax) * ay + p11 * ax * ay
    }

    /// Build from a CVPixelBuffer using Rec. 709 luma weights.
    ///
    /// Handles BGRA and the 420 bi-planar formats, which covers what
    /// AVCaptureVideoDataOutput delivers on iOS. For 420 formats only the
    /// luma plane is read, which is both correct and free.
    public static func from(pixelBuffer: CVPixelBuffer,
                            downsample: Int = 1) -> GrayImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fullWidth = CVPixelBufferGetWidth(pixelBuffer)
        let fullHeight = CVPixelBufferGetHeight(pixelBuffer)
        let step = max(downsample, 1)
        let width = fullWidth / step
        let height = fullHeight / step
        guard width > 0, height > 0 else { return nil }

        var output = [Float](repeating: 0, count: width * height)

        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = (y * step) * stride
                for x in 0..<width {
                    output[y * width + x] = Float(luma[row + x * step])
                }
            }

        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)
            else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = (y * step) * stride
                for x in 0..<width {
                    let i = row + (x * step) * 4
                    let b = Float(bytes[i]), g = Float(bytes[i + 1]), r = Float(bytes[i + 2])
                    output[y * width + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
                }
            }

        default:
            return nil
        }

        return GrayImage(width: width, height: height, pixels: output)
    }
}

/// Physical description of the calibration target.
public struct CheckerboardSpec: Codable, Equatable, Sendable {

    /// Inner corners across, i.e. one fewer than the number of squares.
    public var columns: Int

    /// Inner corners down.
    public var rows: Int

    /// Square edge length in metres.
    public var squareSize: Double

    public init(columns: Int = 9, rows: Int = 6, squareSize: Double = 0.030) {
        self.columns = columns
        self.rows = rows
        self.squareSize = squareSize
    }

    public var cornerCount: Int { columns * rows }

    /// Target corners in board coordinates, Z = 0, row-major.
    public var objectPoints: [SIMD3<Double>] {
        var points = [SIMD3<Double>]()
        points.reserveCapacity(cornerCount)
        for r in 0..<rows {
            for c in 0..<columns {
                points.append(SIMD3(Double(c) * squareSize,
                                    Double(r) * squareSize,
                                    0))
            }
        }
        return points
    }

    /// Ideal grid coordinates used by the fitter, in units of one square.
    public var idealGrid: [SIMD2<Double>] {
        var points = [SIMD2<Double>]()
        for r in 0..<rows {
            for c in 0..<columns {
                points.append(SIMD2(Double(c), Double(r)))
            }
        }
        return points
    }

    public var isValid: Bool {
        columns >= 3 && rows >= 3 && squareSize > 0.001
        // Asymmetric patterns (one side odd, one even) resolve the 180-degree
        // rotation ambiguity. A fully symmetric board can be matched two ways,
        // which silently mirrors the recovered extrinsics.
    }

    public var hasRotationAmbiguity: Bool {
        columns % 2 == rows % 2
    }
}

/// Result of detecting a board in one frame.
public struct CheckerboardDetection: Sendable {
    /// Corners in row-major order matching `CheckerboardSpec.objectPoints`.
    public let corners: [SIMD2<Double>]
    /// Largest deviation of the matched set from its own fitted homography,
    /// in pixels. High values mean a mismatched corner slipped through.
    public let gridResidual: Double
    /// Fraction of the frame area the board covers.
    public let coverage: Double
    /// Mean board position in normalised frame coordinates, for coverage
    /// tracking in the UI.
    public let centre: SIMD2<Double>
    /// Estimated board tilt in degrees, from the perspective foreshortening.
    public let tiltDegrees: Double
}

/// Detects checkerboard corners to subpixel precision.
///
/// Deliberately tuned for precision over recall. The user captures many
/// frames, so rejecting a marginal one costs a second, while accepting a bad
/// one silently corrupts the calibration and every measurement built on it.
public struct CheckerboardDetector {

    public struct Options: Sendable {
        /// Smoothing before the Hessian. Too little and noise dominates the
        /// second derivatives; too much and nearby corners merge.
        public var responseSigma: Double = 1.4

        /// Non-maximum suppression radius in pixels.
        public var suppressionRadius: Int = 6

        /// Candidates weaker than this fraction of the strongest response are
        /// discarded. Without it, noise peaks flooded the candidate list and
        /// the grid fit could not find the lattice at all.
        public var relativeThreshold: Double = 0.08

        /// Maximum candidates carried into refinement.
        public var maximumCandidates: Int = 400

        /// Half-width of the subpixel refinement window.
        public var refinementHalfWindow: Int = 8
        public var refinementIterations: Int = 8
        public var gradientSigma: Double = 1.0

        /// Radius of the circle sampled for the X-junction test.
        public var junctionRadius: Double = 9

        /// Minimum peak-to-peak intensity around that circle. Rejects
        /// low-contrast candidates in shadow or glare.
        public var junctionMinimumAmplitude: Double = 20

        /// Match tolerance during grid fitting, as a fraction of the local
        /// square spacing.
        public var matchToleranceRatio: Double = 0.35

        /// Maximum acceptable grid residual, as a fraction of spacing. Lens
        /// distortion means a single homography cannot fit the whole board
        /// exactly, so this cannot be tight; it is here to catch a genuinely
        /// mismatched corner rather than to measure distortion.
        public var maximumResidualRatio: Double = 0.25

        public init() {}
    }

    public let spec: CheckerboardSpec
    public let options: Options

    public init(spec: CheckerboardSpec = CheckerboardSpec(),
                options: Options = Options()) {
        self.spec = spec
        self.options = options
    }

    // MARK: - Stage 1: saddle response

    /// Gaussian blur, separable, with a fixed kernel radius.
    private func blur(_ image: GrayImage, sigma: Double) -> GrayImage {
        guard sigma > 0.01 else { return image }
        let radius = max(Int((sigma * 3).rounded()), 1)
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        var sum = 0.0
        for i in 0...(2 * radius) {
            let x = Double(i - radius)
            let v = exp(-x * x / (2 * sigma * sigma))
            kernel[i] = v
            sum += v
        }
        for i in kernel.indices { kernel[i] /= sum }

        var horizontal = GrayImage(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                var acc = 0.0
                for k in 0...(2 * radius) {
                    let xi = min(max(x + k - radius, 0), image.width - 1)
                    acc += kernel[k] * Double(image[xi, y])
                }
                horizontal[x, y] = Float(acc)
            }
        }

        var output = GrayImage(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                var acc = 0.0
                for k in 0...(2 * radius) {
                    let yi = min(max(y + k - radius, 0), image.height - 1)
                    acc += kernel[k] * Double(horizontal[x, yi])
                }
                output[x, y] = Float(acc)
            }
        }
        return output
    }

    /// Central-difference gradient.
    private func gradient(_ image: GrayImage) -> (gx: GrayImage, gy: GrayImage) {
        var gx = GrayImage(width: image.width, height: image.height)
        var gy = GrayImage(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let xm = max(x - 1, 0), xp = min(x + 1, image.width - 1)
                let ym = max(y - 1, 0), yp = min(y + 1, image.height - 1)
                gx[x, y] = (image[xp, y] - image[xm, y]) * 0.5
                gy[x, y] = (image[x, yp] - image[x, ym]) * 0.5
            }
        }
        return (gx, gy)
    }

    /// Candidate corners from the saddle response, after suppression and
    /// thresholding.
    private func candidates(in image: GrayImage) -> [SIMD2<Double>] {
        let smoothed = blur(image, sigma: options.responseSigma)
        let (gx, gy) = gradient(smoothed)
        let (gxx, gxy) = gradient(gx)
        let (gyx, gyy) = gradient(gy)

        // Checkerboard corners are saddles, so det(Hessian) is negative.
        // Working with the negated determinant makes them maxima.
        var response = GrayImage(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let det = Double(gxx[x, y]) * Double(gyy[x, y])
                        - Double(gxy[x, y]) * Double(gyx[x, y])
                response[x, y] = Float(max(-det, 0))
            }
        }

        let margin = options.refinementHalfWindow + 4
        var peaks = [(point: SIMD2<Double>, value: Float)]()
        let r = options.suppressionRadius

        for y in margin..<(image.height - margin) {
            for x in margin..<(image.width - margin) {
                let value = response[x, y]
                if value <= 0 { continue }
                var isPeak = true
                var dy = -r
                while dy <= r && isPeak {
                    var dx = -r
                    while dx <= r {
                        if dx != 0 || dy != 0 {
                            if response[x + dx, y + dy] > value { isPeak = false; break }
                        }
                        dx += 1
                    }
                    dy += 1
                }
                if isPeak {
                    peaks.append((SIMD2(Double(x), Double(y)), value))
                }
            }
        }

        guard let strongest = peaks.map(\.value).max(), strongest > 0 else {
            return []
        }
        let cutoff = Float(options.relativeThreshold) * strongest

        return peaks
            .filter { $0.value >= cutoff }
            .sorted { $0.value > $1.value }
            .prefix(options.maximumCandidates)
            .map(\.point)
    }

    // MARK: - Stage 2: subpixel refinement

    /// Refine to subpixel by gradient orthogonality.
    ///
    /// At a true saddle the image gradient at every nearby pixel is
    /// perpendicular to the vector from the corner to that pixel. Stacking
    /// `g g^T q = g g^T p` over a window and solving gives the corner
    /// directly. Exact for an ideal checkerboard, and converges in a handful
    /// of iterations.
    private func refine(_ candidates: [SIMD2<Double>],
                        in image: GrayImage) -> [SIMD2<Double>] {
        let smoothed = blur(image, sigma: options.gradientSigma)
        let (gx, gy) = gradient(smoothed)
        let half = options.refinementHalfWindow
        let weightSigma = Double(half)

        return candidates.map { start -> SIMD2<Double> in
            var q = start
            for _ in 0..<options.refinementIterations {
                let cx = Int(q.x.rounded()), cy = Int(q.y.rounded())
                guard cx - half >= 0, cy - half >= 0,
                      cx + half < image.width, cy + half < image.height
                else { break }

                var a00 = 0.0, a01 = 0.0, a11 = 0.0
                var b0 = 0.0, b1 = 0.0

                for y in (cy - half)...(cy + half) {
                    for x in (cx - half)...(cx + half) {
                        let dx = Double(x) - q.x, dy = Double(y) - q.y
                        let weight = exp(-(dx * dx + dy * dy)
                                         / (2 * weightSigma * weightSigma))
                        let gxv = Double(gx[x, y]) * weight
                        let gyv = Double(gy[x, y]) * weight
                        let gxr = Double(gx[x, y])
                        let gyr = Double(gy[x, y])

                        a00 += gxv * gxr
                        a01 += gxv * gyr
                        a11 += gyv * gyr
                        b0 += gxv * gxr * Double(x) + gxv * gyr * Double(y)
                        b1 += gyv * gxr * Double(x) + gyv * gyr * Double(y)
                    }
                }

                let det = a00 * a11 - a01 * a01
                guard abs(det) > 1e-12 else { break }

                let nx = (b0 * a11 - a01 * b1) / det
                let ny = (a00 * b1 - a01 * b0) / det
                guard nx.isFinite, ny.isFinite else { break }

                let next = SIMD2(nx, ny)
                let step = simd_length(next - q)
                // A large jump means the window drifted onto a different
                // feature; keep the previous estimate rather than follow it.
                guard step < Double(half) else { break }
                q = next
                if step < 1e-5 { break }
            }
            return q
        }
    }

    // MARK: - Stage 3: X-junction discrimination

    /// True when intensity around a circle alternates dark-bright-dark-bright.
    ///
    /// This is the single most valuable filter in the pipeline. Where the
    /// printed pattern meets its white quiet zone, T-junctions produce a
    /// strong saddle response but only two sign changes around the circle; a
    /// real corner produces exactly four. In validation this removed all 64
    /// spurious candidates while keeping all 54 true corners, and without it
    /// the grid fit failed on every frame.
    private func isXJunction(at point: SIMD2<Double>, in image: GrayImage) -> Bool {
        let samples = 32
        var values = [Double]()
        values.reserveCapacity(samples)

        for i in 0..<samples {
            let angle = 2 * Double.pi * Double(i) / Double(samples)
            let x = point.x + options.junctionRadius * cos(angle)
            let y = point.y + options.junctionRadius * sin(angle)
            guard let v = image.sample(x: x, y: y) else { return false }
            values.append(v)
        }

        guard let lo = values.min(), let hi = values.max(),
              hi - lo >= options.junctionMinimumAmplitude else { return false }

        let mean = values.reduce(0, +) / Double(values.count)
        var changes = 0
        for i in 0..<samples {
            let a = values[i] - mean
            let b = values[(i + 1) % samples] - mean
            if (a >= 0) != (b >= 0) { changes += 1 }
        }
        return changes == 4
    }

    // MARK: - Stage 4: grid fitting

    /// Hartley normalisation: centroid to origin, mean distance sqrt(2).
    private func normalise(_ points: [SIMD2<Double>])
        -> (points: [SIMD2<Double>], transform: [[Double]]) {
        let n = Double(points.count)
        let mean = points.reduce(SIMD2<Double>(0, 0), +) / n
        let meanDistance = points
            .map { simd_length($0 - mean) }
            .reduce(0, +) / n
        let s = meanDistance > 1e-12 ? 2.0.squareRoot() / meanDistance : 1.0
        let T = [[s, 0, -s * mean.x],
                 [0, s, -s * mean.y],
                 [0, 0, 1.0]]
        return (points.map { SIMD2(s * ($0.x - mean.x), s * ($0.y - mean.y)) }, T)
    }

    /// Direct linear transform homography, normalised.
    func homography(from source: [SIMD2<Double>],
                    to destination: [SIMD2<Double>]) -> [[Double]]? {
        guard source.count >= 4, source.count == destination.count else { return nil }

        let (sn, Ts) = normalise(source)
        let (dn, Td) = normalise(destination)

        var A = [[Double]]()
        for (s, d) in zip(sn, dn) {
            A.append([-s.x, -s.y, -1, 0, 0, 0, d.x * s.x, d.x * s.y, d.x])
            A.append([0, 0, 0, -s.x, -s.y, -1, d.y * s.x, d.y * s.y, d.y])
        }

        let h = LinearAlgebra.smallestSingularVector(A)
        guard h.count == 9 else { return nil }
        let Hn = [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], h[8]]]

        guard let TdInv = LinearAlgebra.invert(Td) else { return nil }
        var H = LinearAlgebra.multiply(LinearAlgebra.multiply(TdInv, Hn), Ts)

        guard abs(H[2][2]) > 1e-12 else { return nil }
        let scale = H[2][2]
        for i in 0..<3 { for j in 0..<3 { H[i][j] /= scale } }
        return H
    }

    func apply(_ H: [[Double]], to point: SIMD2<Double>) -> SIMD2<Double> {
        let w = H[2][0] * point.x + H[2][1] * point.y + H[2][2]
        guard abs(w) > 1e-12 else { return SIMD2(0, 0) }
        return SIMD2((H[0][0] * point.x + H[0][1] * point.y + H[0][2]) / w,
                     (H[1][0] * point.x + H[1][1] * point.y + H[1][2]) / w)
    }

    /// Match detected corners to the known lattice.
    ///
    /// The pattern dimensions are a strong prior. The four extreme points
    /// give an initial homography from the ideal grid; every ideal corner is
    /// mapped through it and matched to its nearest unused detection, then
    /// the homography is refitted on the full correspondence set and the
    /// process repeated. Accepts only when every corner matches.
    private func fitGrid(_ points: [SIMD2<Double>])
        -> (corners: [SIMD2<Double>], residual: Double)? {

        guard points.count >= spec.cornerCount else { return nil }

        let centre = points.reduce(SIMD2<Double>(0, 0), +) / Double(points.count)
        var extremeIndices = [Int]()
        for (sx, sy) in [(1.0, 1.0), (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0)] {
            var best = 0
            var bestScore = -Double.infinity
            for (i, p) in points.enumerated() {
                let score = sx * (p.x - centre.x) + sy * (p.y - centre.y)
                if score > bestScore { bestScore = score; best = i }
            }
            extremeIndices.append(best)
        }
        guard Set(extremeIndices).count == 4 else { return nil }

        let quad = extremeIndices.map { points[$0] }
        let idealQuad: [SIMD2<Double>] = [
            SIMD2(Double(spec.columns - 1), Double(spec.rows - 1)),
            SIMD2(Double(spec.columns - 1), 0),
            SIMD2(0, 0),
            SIMD2(0, Double(spec.rows - 1)),
        ]

        guard var H = homography(from: idealQuad, to: quad) else { return nil }
        let ideal = spec.idealGrid
        var matched = [SIMD2<Double>]()

        for _ in 0..<3 {
            let predicted = ideal.map { apply(H, to: $0) }
            let spacing = simd_length(apply(H, to: SIMD2(1, 0))
                                      - apply(H, to: SIMD2(0, 0)))
            guard spacing > 2 else { return nil }
            let tolerance = spacing * options.matchToleranceRatio

            matched.removeAll(keepingCapacity: true)
            var used = Set<Int>()
            var complete = true

            for p in predicted {
                var bestIndex = -1
                var bestDistance = Double.infinity
                for (i, c) in points.enumerated() where !used.contains(i) {
                    let d = simd_length(c - p)
                    if d < bestDistance { bestDistance = d; bestIndex = i }
                }
                guard bestIndex >= 0, bestDistance < tolerance else {
                    complete = false; break
                }
                used.insert(bestIndex)
                matched.append(points[bestIndex])
            }

            guard complete else { return nil }
            guard let refit = homography(from: ideal, to: matched) else { return nil }
            H = refit
        }

        // Final consistency check. A corner matched to the wrong lattice site
        // can still produce a complete set, and shows up only here.
        let predicted = ideal.map { apply(H, to: $0) }
        var residual = 0.0
        for (p, m) in zip(predicted, matched) {
            residual = max(residual, simd_length(p - m))
        }
        let spacing = simd_length(apply(H, to: SIMD2(1, 0))
                                  - apply(H, to: SIMD2(0, 0)))
        guard residual < spacing * options.maximumResidualRatio else { return nil }

        return (matched, residual)
    }

    // MARK: - Public entry point

    public func detect(in image: GrayImage) -> CheckerboardDetection? {
        let raw = candidates(in: image)
        guard raw.count >= spec.cornerCount else { return nil }

        let refined = refine(raw, in: image)
        let junctions = refined.filter { isXJunction(at: $0, in: image) }
        guard junctions.count >= spec.cornerCount else { return nil }

        guard let (corners, residual) = fitGrid(junctions) else { return nil }

        // Coverage and geometry, used by the UI to steer the user toward the
        // pose diversity the calibration actually needs.
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let boardWidth = (xs.max() ?? 0) - (xs.min() ?? 0)
        let boardHeight = (ys.max() ?? 0) - (ys.min() ?? 0)
        let coverage = (boardWidth * boardHeight)
                     / Double(image.width * image.height)

        let centre = SIMD2(corners.reduce(0.0) { $0 + $1.x } / Double(corners.count)
                            / Double(image.width),
                           corners.reduce(0.0) { $0 + $1.y } / Double(corners.count)
                            / Double(image.height))

        // Tilt from foreshortening: compare the length of the top edge with
        // the bottom edge, and the left with the right.
        let topLeft = corners[0]
        let topRight = corners[spec.columns - 1]
        let bottomLeft = corners[(spec.rows - 1) * spec.columns]
        let bottomRight = corners[corners.count - 1]
        let topLength = simd_length(topRight - topLeft)
        let bottomLength = simd_length(bottomRight - bottomLeft)
        let leftLength = simd_length(bottomLeft - topLeft)
        let rightLength = simd_length(bottomRight - topRight)

        let horizontalRatio = min(topLength, bottomLength) / max(topLength, bottomLength, 1e-9)
        let verticalRatio = min(leftLength, rightLength) / max(leftLength, rightLength, 1e-9)
        let tilt = acos(max(min(min(horizontalRatio, verticalRatio), 1), 0)) * 180 / .pi

        return CheckerboardDetection(corners: corners,
                                     gridResidual: residual,
                                     coverage: coverage,
                                     centre: centre,
                                     tiltDegrees: tilt)
    }
}
