import Foundation
import simd

/// A saved, reusable calibration tied to one physical camera setup.
///
/// This type is the centre of the consistency design. Calibration error is
/// dominated by how precisely a human taps four corners on a phone screen —
/// roughly 10 mm of distance uncertainty per 2 px of tap noise. That error is
/// mostly a scale error on every measurement derived from it.
///
/// The important property: if you re-solve the calibration every session, the
/// scale error is redrawn each time and enters every session-to-session
/// comparison twice. If you solve once and reuse the stored profile, the
/// scale error becomes a fixed offset that cancels exactly out of any
/// comparison between sessions on that setup.
///
/// So the tool deliberately makes reuse the default path and re-solving the
/// exception. An athlete comparing this week's hop distance to last week's
/// gets a difference limited by pose noise, not by how steadily they tapped.
/// The absolute number may be off by a centimetre; the change between
/// sessions will not be.
public struct CalibrationProfile: Codable, Identifiable, Equatable, Sendable {

    public let id: UUID

    /// User-facing name, e.g. "North runway, 4m mark".
    public var name: String

    public var createdAt: Date
    public var lastUsedAt: Date
    public var lastVerifiedAt: Date

    public var intrinsics: CameraIntrinsics
    public var pose: CameraPose
    public var pipe: ReferencePipe

    /// The taps this profile was solved from. Kept so the solve can be
    /// audited, re-run under a corrected pipe height, or compared against a
    /// later verification.
    public var observations: CalibrationObservations

    public var reprojectionRMSE: Double
    public var maxPointError: Double

    /// Physical setup notes the user records so the rig can be rebuilt
    /// identically: tripod leg marks, floor tape positions, pipe placement.
    public var setupNotes: String

    /// Number of sessions captured against this profile. High counts mean a
    /// long comparable history that would be broken by re-solving.
    public var sessionCount: Int

    public init(id: UUID = UUID(),
                name: String,
                intrinsics: CameraIntrinsics,
                pose: CameraPose,
                pipe: ReferencePipe,
                observations: CalibrationObservations,
                reprojectionRMSE: Double,
                maxPointError: Double,
                setupNotes: String = "",
                sessionCount: Int = 0,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.intrinsics = intrinsics
        self.pose = pose
        self.pipe = pipe
        self.observations = observations
        self.reprojectionRMSE = reprojectionRMSE
        self.maxPointError = maxPointError
        self.setupNotes = setupNotes
        self.sessionCount = sessionCount
        self.createdAt = createdAt
        self.lastUsedAt = createdAt
        self.lastVerifiedAt = createdAt
    }

    public var cameraModel: CameraModel {
        CameraModel(intrinsics: intrinsics, pose: pose)
    }
}

/// Quality thresholds for accepting a calibration.
///
/// The RMSE gate is set from the validated noise model: with yaw and pitch
/// solved, RMSE reflects tap precision alone and sits near 1.6 px for typical
/// (2 px) tapping, with a 99th percentile around 2.5 px. A 4 px gate passes
/// normal use comfortably while still catching a mistapped corner, a
/// misidentified reference marker, or a pipe that has been knocked over.
public enum CalibrationQuality {

    public static let excellentRMSE: Double = 1.5
    public static let acceptableRMSE: Double = 4.0
    public static let maxSinglePointError: Double = 8.0

    /// Yaw beyond this suggests the tripod is badly placed. The solve handles
    /// it correctly, but a large yaw means the athlete's plane of motion is
    /// obliquely viewed, which degrades every sagittal measurement.
    public static let maxComfortableYaw: Double = 8.0 * .pi / 180

    public enum Grade: String, Codable, Sendable {
        case excellent, acceptable, poor, rejected
    }

    public static func grade(_ result: CalibrationResult) -> Grade {
        if result.maxPointError > maxSinglePointError { return .rejected }
        if result.reprojectionRMSE > acceptableRMSE { return .rejected }
        if abs(result.pose.yaw) > maxComfortableYaw { return .poor }
        if result.reprojectionRMSE <= excellentRMSE { return .excellent }
        return .acceptable
    }

    /// Human-readable guidance, naming the specific problem where possible.
    public static func advice(_ result: CalibrationResult) -> String? {
        if result.maxPointError > maxSinglePointError {
            let idx = result.pointErrors.firstIndex(of: result.maxPointError) ?? 0
            let labels = WorldFrame.boardCornerLabels + ["Pipe base", "Pipe top"]
            let label = idx < labels.count ? labels[idx] : "a reference point"
            return "\(label) looks mistapped "
                 + "(\(String(format: "%.1f", result.maxPointError)) px off). Re-tap it."
        }
        if result.reprojectionRMSE > acceptableRMSE {
            return "Reference points do not fit a consistent camera position. "
                 + "Check the pipe is vertical and its measured height is correct."
        }
        if abs(result.pose.yaw) > maxComfortableYaw {
            let deg = result.pose.yaw * 180 / .pi
            return "Tripod is about \(String(format: "%.1f", abs(deg)))° off perpendicular. "
                 + "Measurements will still be scaled correctly, but squaring "
                 + "the tripod to the board will improve joint angle accuracy."
        }
        return nil
    }
}

/// Result of checking a stored profile against the current camera view.
public struct VerificationResult: Sendable {

    /// Distance the current view implies, versus the stored profile.
    public let currentDistance: Double
    public let storedDistance: Double

    /// How far the physical setup appears to have shifted, in metres.
    public var drift: Double { abs(currentDistance - storedDistance) }

    /// Reprojection RMSE when the stored pose is applied to the current taps.
    public let rmseWithStoredPose: Double

    public let recommendation: Recommendation

    public enum Recommendation: Sendable, Equatable {
        /// Setup is unchanged. Keep using the stored profile and preserve
        /// comparability with the entire session history.
        case reuseProfile

        /// Setup has shifted slightly. Reusing is still the better choice —
        /// the residual bias is smaller than the noise that re-solving would
        /// inject, and comparability is preserved.
        case reuseWithMinorDrift(driftMillimetres: Double)

        /// Setup has genuinely moved. Re-solving is now necessary, and the
        /// user must be told plainly that new sessions will not be directly
        /// comparable to older ones.
        case recalibrateRequired(reason: String)
    }
}

/// Drift thresholds governing when a stored profile stops being trustworthy.
public enum ProfileVerification {

    /// Below this, treat the setup as unchanged.
    public static let negligibleDrift: Double = 0.015   // 15 mm

    /// Between negligible and this, keep reusing: the induced bias is smaller
    /// than the fresh tap noise that re-solving would introduce.
    public static let tolerableDrift: Double = 0.060    // 60 mm

    /// Verify a stored profile against a fresh set of taps.
    ///
    /// The user is asked to re-tap the references periodically — not to
    /// replace the calibration, but to confirm nothing has moved. The default
    /// outcome is to keep the stored numbers.
    public static func verify(profile: CalibrationProfile,
                              freshObservations obs: CalibrationObservations,
                              solver: CalibrationSolver) -> VerificationResult {

        // How well does the STORED pose explain the FRESH taps? This is the
        // direct question, and it does not depend on re-solving anything.
        let storedModel = profile.cameraModel
        let worldPoints = WorldFrame.boardCorners
            + [profile.pipe.basePosition, profile.pipe.topPosition]
        let observedPixels = obs.boardCorners + [obs.pipeBase, obs.pipeTop]

        var sumSquares = 0.0
        var count = 0
        for (w, o) in zip(worldPoints, observedPixels) {
            guard let p = storedModel.project(w) else { continue }
            let dx = p.x - o.x, dy = p.y - o.y
            sumSquares += dx * dx + dy * dy
            count += 1
        }
        let rmse = count > 0 ? (sumSquares / Double(count)).squareRoot() : .infinity

        // A trial re-solve, used only to quantify drift — not adopted.
        let trialDistance: Double
        if let trial = try? solver.solve(observations: obs) {
            trialDistance = trial.pose.distance
        } else {
            return VerificationResult(
                currentDistance: .nan,
                storedDistance: profile.pose.distance,
                rmseWithStoredPose: rmse,
                recommendation: .recalibrateRequired(
                    reason: "Current view could not be solved. Check that the "
                          + "board and reference pipe are fully visible."))
        }

        let drift = abs(trialDistance - profile.pose.distance)

        let recommendation: VerificationResult.Recommendation
        if drift < negligibleDrift {
            recommendation = .reuseProfile
        } else if drift < tolerableDrift {
            recommendation = .reuseWithMinorDrift(driftMillimetres: drift * 1000)
        } else {
            recommendation = .recalibrateRequired(
                reason: "Camera appears to have moved about "
                      + "\(String(format: "%.0f", drift * 1000)) mm since this profile "
                      + "was created. Measurements from a new calibration will not be "
                      + "directly comparable to earlier sessions on this profile.")
        }

        return VerificationResult(currentDistance: trialDistance,
                                  storedDistance: profile.pose.distance,
                                  rmseWithStoredPose: rmse,
                                  recommendation: recommendation)
    }
}

/// On-device storage for calibration profiles.
public actor CalibrationProfileStore {

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            self.directory = base.appendingPathComponent("CalibrationProfiles",
                                                         isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory,
                                                withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ profile: CalibrationProfile) throws {
        try encoder.encode(profile).write(to: url(for: profile.id), options: .atomic)
    }

    public func load(id: UUID) throws -> CalibrationProfile {
        try decoder.decode(CalibrationProfile.self,
                           from: Data(contentsOf: url(for: id)))
    }

    public func loadAll() throws -> [CalibrationProfile] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(CalibrationProfile.self,
                                              from: Data(contentsOf: $0)) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    public func recordUse(id: UUID) throws {
        var profile = try load(id: id)
        profile.lastUsedAt = Date()
        profile.sessionCount += 1
        try save(profile)
    }

    public func recordVerification(id: UUID) throws {
        var profile = try load(id: id)
        profile.lastVerifiedAt = Date()
        try save(profile)
    }
}
