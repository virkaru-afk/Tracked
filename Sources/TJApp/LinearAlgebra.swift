import Foundation

/// Small dense linear algebra, written out rather than pulled from a library.
///
/// The matrices this project solves are at most 9x9, so an external
/// dependency would buy nothing in speed while costing a great deal in
/// integration. Three concrete reasons for hand-rolling:
///
///   - No OpenCV. Adding it would mean a ~200 MB framework, an Objective-C++
///     bridging layer and a second CocoaPod alongside MediaPipe.
///   - No Accelerate LAPACK. Those symbols carry deprecation and
///     new-LAPACK-flag friction across SDK versions.
///   - Determinism. A fixed algorithm with fixed iteration counts produces
///     bit-identical output on every device and every OS release, which is
///     the property the whole project is built around.
public enum LinearAlgebra {

    // MARK: - Symmetric eigendecomposition

    /// Cyclic Jacobi eigendecomposition of a symmetric matrix.
    ///
    /// Returns eigenvalues and eigenvectors as columns, i.e. `vectors[i][j]`
    /// is row i of eigenvector j.
    ///
    /// Two numerical guards, both of which fired during validation on real
    /// calibration matrices and would otherwise have produced NaN:
    ///
    ///   1. `theta * theta` overflows to infinity when an off-diagonal is
    ///      tiny relative to the difference of its diagonals. The large-theta
    ///      limit t -> 1/(2*theta) is used instead.
    ///   2. The off-diagonal norm must be summed directly. Computing it as
    ///      `sqrt(sumOfSquares - diagonalSquares)` can go slightly negative
    ///      through rounding and yield NaN.
    public static func symmetricEigen(_ matrix: [[Double]],
                                      maxSweeps: Int = 60,
                                      tolerance: Double = 1e-15)
        -> (values: [Double], vectors: [[Double]]) {

        let n = matrix.count
        var a = matrix
        var v = identity(n)

        for _ in 0..<maxSweeps {
            // Guard 2: sum off-diagonals directly.
            var offSquared = 0.0
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    offSquared += a[p][q] * a[p][q]
                }
            }
            if (2 * offSquared).squareRoot() < tolerance { break }

            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = a[p][q]
                    if abs(apq) < 1e-300 { continue }

                    let theta = (a[q][q] - a[p][p]) / (2 * apq)

                    // Guard 1: avoid squaring a huge theta.
                    let t: Double
                    if abs(theta) > 1e150 {
                        t = 1.0 / (2 * theta)
                    } else {
                        let sign: Double = theta >= 0 ? 1 : -1
                        t = sign / (abs(theta) + (theta * theta + 1).squareRoot())
                    }

                    let c = 1.0 / (t * t + 1).squareRoot()
                    let s = t * c

                    // Apply the rotation in place: J^T a J and v J.
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }

        let values = (0..<n).map { a[$0][$0] }
        return (values, v)
    }

    /// Right singular vector of `A` with the smallest singular value.
    ///
    /// Obtained as the eigenvector of A^T A for the smallest eigenvalue.
    /// Forming A^T A squares the condition number, which is why every caller
    /// applies Hartley normalisation to its input first.
    public static func smallestSingularVector(_ A: [[Double]]) -> [Double] {
        let rows = A.count
        guard rows > 0 else { return [] }
        let cols = A[0].count

        var AtA = [[Double]](repeating: [Double](repeating: 0, count: cols),
                             count: cols)
        for i in 0..<cols {
            for j in i..<cols {
                var sum = 0.0
                for k in 0..<rows { sum += A[k][i] * A[k][j] }
                AtA[i][j] = sum
                AtA[j][i] = sum
            }
        }

        let (values, vectors) = symmetricEigen(AtA)
        var smallest = 0
        for i in 1..<values.count where values[i] < values[smallest] {
            smallest = i
        }
        return (0..<cols).map { vectors[$0][smallest] }
    }

    // MARK: - Basic operations

    public static func identity(_ n: Int) -> [[Double]] {
        var m = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { m[i][i] = 1 }
        return m
    }

    public static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        let n = a.count, m = b[0].count, k = b.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                var sum = 0.0
                for x in 0..<k { sum += a[i][x] * b[x][j] }
                out[i][j] = sum
            }
        }
        return out
    }

    public static func transpose(_ a: [[Double]]) -> [[Double]] {
        guard let first = a.first else { return [] }
        return (0..<first.count).map { j in a.map { $0[j] } }
    }

    /// Gauss-Jordan inverse with partial pivoting. Returns nil if singular.
    public static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var a = matrix
        var inv = identity(n)

        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) {
                pivot = r
            }
            guard abs(a[pivot][col]) > 1e-14 else { return nil }
            if pivot != col {
                a.swapAt(col, pivot)
                inv.swapAt(col, pivot)
            }
            let d = a[col][col]
            for j in 0..<n {
                a[col][j] /= d
                inv[col][j] /= d
            }
            for r in 0..<n where r != col {
                let f = a[r][col]
                if f == 0 { continue }
                for j in 0..<n {
                    a[r][j] -= f * a[col][j]
                    inv[r][j] -= f * inv[col][j]
                }
            }
        }
        return inv
    }

    /// Solve `A x = b` by Gaussian elimination with partial pivoting.
    public static func solve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = A.count
        var a = A
        var rhs = b

        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) {
                pivot = r
            }
            guard abs(a[pivot][col]) > 1e-14 else { return nil }
            if pivot != col {
                a.swapAt(col, pivot)
                rhs.swapAt(col, pivot)
            }
            for r in (col + 1)..<n {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for j in col..<n { a[r][j] -= f * a[col][j] }
                rhs[r] -= f * rhs[col]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = rhs[i]
            for j in (i + 1)..<n { sum -= a[i][j] * x[j] }
            x[i] = sum / a[i][i]
        }
        return x
    }

    /// Nearest rotation matrix to `m`, via one step of Newton-Schulz
    /// orthogonalisation repeated to convergence.
    ///
    /// Used to clean up the rotation recovered from a homography, whose
    /// columns are only approximately orthonormal once noise is present.
    /// Avoids needing a general SVD for a 3x3 polar decomposition.
    public static func nearestRotation(_ m: [[Double]]) -> [[Double]] {
        var r = m
        for _ in 0..<24 {
            guard let inverse = invert(transpose(r)) else { break }
            var next = [[Double]](repeating: [Double](repeating: 0, count: 3),
                                  count: 3)
            var delta = 0.0
            for i in 0..<3 {
                for j in 0..<3 {
                    next[i][j] = 0.5 * (r[i][j] + inverse[i][j])
                    delta += abs(next[i][j] - r[i][j])
                }
            }
            r = next
            if delta < 1e-14 { break }
        }
        return r
    }

    public static func determinant3x3(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }
}
