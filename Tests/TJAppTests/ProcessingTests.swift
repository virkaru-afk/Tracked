import XCTest
import simd
@testable import TJApp

final class SignalProcessingTests: XCTestCase {

    /// Determinism is the whole reason Savitzky-Golay was chosen over a
    /// Kalman filter. If this ever fails, run-to-run reproducibility is gone.
    func testFilterIsDeterministic() {
        let filter = SavitzkyGolay(windowLength: 9, polynomialOrder: 2)
        let input = (0..<200).map { sin(Double($0) * 0.1) + cos(Double($0) * 0.03) }

        let first = filter.apply(input, derivative: 1, sampleInterval: 1.0 / 150)
        let second = filter.apply(input, derivative: 1, sampleInterval: 1.0 / 150)

        for (a, b) in zip(first, second) {
            XCTAssertEqual(a, b, accuracy: 0,
                           "Filter output must be bit-identical across calls")
        }
    }

    func testSmoothingPreservesConstant() {
        let filter = SavitzkyGolay(windowLength: 9, polynomialOrder: 2)
        let input = [Double](repeating: 3.7, count: 50)
        for value in filter.apply(input) {
            XCTAssertEqual(value, 3.7, accuracy: 1e-9)
        }
    }

    func testFirstDerivativeOfLinearRamp() {
        let filter = SavitzkyGolay(windowLength: 9, polynomialOrder: 2)
        let dt = 1.0 / 150
        let slope = 4.5
        let input = (0..<100).map { Double($0) * dt * slope }

        let derivative = filter.apply(input, derivative: 1, sampleInterval: dt)
        // Interior only: edge clamping deliberately flattens the boundary.
        for value in derivative[10..<90] {
            XCTAssertEqual(value, slope, accuracy: 1e-6)
        }
    }

    func testSecondDerivativeOfQuadratic() {
        let filter = SavitzkyGolay(windowLength: 13, polynomialOrder: 3)
        let dt = 1.0 / 150
        let acceleration = -9.81
        let input = (0..<150).map { i -> Double in
            let t = Double(i) * dt
            return 0.5 * acceleration * t * t
        }

        let second = filter.apply(input, derivative: 2, sampleInterval: dt)
        for value in second[15..<135] {
            XCTAssertEqual(value, acceleration, accuracy: 0.01)
        }
    }

    /// Windows are specified in milliseconds so the effective smoothing is
    /// the same real duration regardless of capture rate.
    func testWindowsConvertToOddSampleCounts() {
        for milliseconds in [33.3, 53.3, 80.0, 100.0] {
            let samples = ProcessingTimebase.Window.samples(milliseconds: milliseconds)
            XCTAssertEqual(samples % 2, 1, "Window must be odd, got \(samples)")
            XCTAssertGreaterThanOrEqual(samples, 5)
        }
    }

    func testResamplerHitsExactGridPoints() {
        let timestamps = (0..<50).map { Double($0) / 149.7 }
        let values = timestamps.map { $0 * 3.0 }
        let grid = Resampler.grid(from: timestamps.first!, to: timestamps.last!)

        let resampled = Resampler.resample(timestamps: timestamps,
                                           values: values, toGrid: grid)

        XCTAssertEqual(resampled.count, grid.count)
        for (t, v) in zip(grid, resampled) {
            XCTAssertEqual(v, t * 3.0, accuracy: 1e-6)
        }
    }

    func testGridSpacingMatchesAnalysisRate() {
        let grid = Resampler.grid(from: 0, to: 1.0)
        XCTAssertEqual(grid[1] - grid[0],
                       ProcessingTimebase.sampleInterval, accuracy: 1e-12)
    }
}

final class EventDetectionTests: XCTestCase {

    /// Build a foot trajectory with correct kinematics: stationary while
    /// planted, arcing forward during flight.
    private func syntheticFootFrames(contactDurations: [Double] = [0.125, 0.145, 0.160],
                                     flightDurations: [Double] = [0.60, 0.52, 0.64],
                                     phaseDistances: [Double] = [5.30, 4.40, 5.60],
                                     noiseMetres: Double = 0)
        -> [ReconstructedFrame] {

        let dt = ProcessingTimebase.sampleInterval
        var frames = [ReconstructedFrame]()
        var t = 0.0
        var x = -1.0
        var index = 0
        var state: UInt64 = 99

        func noise() -> Double {
            guard noiseMetres > 0 else { return 0 }
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double((state >> 11) & 0xFFFFFF) / Double(0xFFFFFF)
            return (u - 0.5) * 2 * noiseMetres
        }

        func append(x px: Double, z pz: Double) {
            let position = SIMD3(px + noise(), 0.12, max(pz + noise(), 0))
            var keypoints = [PoseLandmark: Keypoint3D]()
            for landmark in [PoseLandmark.leftFootIndex, .leftHeel, .leftAnkle] {
                let offset: SIMD3<Double> = landmark == .leftAnkle
                    ? SIMD3(0, 0, 0.08) : .zero
                keypoints[landmark] = Keypoint3D(position: position + offset,
                                                 confidence: 0.9,
                                                 method: .sagittalPlane)
            }
            keypoints[.leftHip] = Keypoint3D(position: SIMD3(px, 0.12, 0.95),
                                             confidence: 0.9, method: .sagittalPlane)
            keypoints[.rightHip] = Keypoint3D(position: SIMD3(px, 0.12, 0.95),
                                              confidence: 0.9, method: .sagittalPlane)
            frames.append(ReconstructedFrame(timestamp: t, frameIndex: index,
                                             keypoints: keypoints))
            t += dt
            index += 1
        }

        // Lead-in flight so the first contact has a proper entry edge.
        for i in 0..<30 {
            let a = Double(i) / 30
            append(x: x + a * 0.8, z: 0.02 + 0.4 * sin(.pi * a))
        }
        x += 0.8

        for phase in 0..<3 {
            let contactFrames = Int((contactDurations[phase] / dt).rounded())
            for _ in 0..<contactFrames { append(x: x, z: 0.018) }

            let flightFrames = Int((flightDurations[phase] / dt).rounded())
            let distance = phaseDistances[phase]
            for i in 0..<flightFrames {
                let a = Double(i) / Double(flightFrames)
                append(x: x + distance * a, z: 0.02 + 0.55 * sin(.pi * a))
            }
            x += distance
        }
        return frames
    }

    func testDetectsThreeContacts() {
        let frames = syntheticFootFrames()
        let contacts = EventDetector().detectContacts(frames: frames)
        XCTAssertEqual(contacts.count, 3, "Expected three ground contacts")
    }

    /// Regression test for the largest bug found during validation.
    ///
    /// The original detector used velocity gates to place the contact
    /// boundaries. Because the velocity filter spans 60 ms, it smeared the
    /// sharp transition at touchdown and truncated measured contact times by
    /// about 45 ms — a 36% underestimate. Boundaries now come from the
    /// unsmeared height signal.
    func testContactDurationIsNotTruncated() {
        let expected = [0.125, 0.145, 0.160]
        let frames = syntheticFootFrames(contactDurations: expected)
        let contacts = EventDetector().detectContacts(frames: frames)

        XCTAssertEqual(contacts.count, 3)
        guard contacts.count == 3 else { return }

        for (contact, truth) in zip(contacts, expected) {
            let error = abs(contact.contact.duration - truth)
            XCTAssertLessThan(error, 0.020,
                "Contact duration off by \(error * 1000) ms "
                + "(measured \(contact.contact.duration * 1000) ms, "
                + "expected \(truth * 1000) ms). "
                + "Are boundaries being taken from the velocity gate again?")
        }
    }

    /// Second regression test from validation. Reading the plant position
    /// from a boundary frame inflated phase-distance spread from 5 mm to
    /// 228 mm, because boundary frames are where the foot is moving fastest.
    func testPlantPositionUsesStationaryCore() {
        let distances = [5.30, 4.40, 5.60]
        let frames = syntheticFootFrames(phaseDistances: distances,
                                         noiseMetres: 0.004)
        let contacts = EventDetector().detectContacts(frames: frames)

        XCTAssertEqual(contacts.count, 3)
        guard contacts.count == 3 else { return }

        let positions = contacts.compactMap {
            EventDetector.plantPosition(contact: $0.contact,
                                        frames: frames,
                                        landmark: .leftFootIndex)
        }
        XCTAssertEqual(positions.count, 3)
        guard positions.count == 3 else { return }

        let measuredHop = positions[1].x - positions[0].x
        let measuredStep = positions[2].x - positions[1].x

        XCTAssertEqual(measuredHop, distances[0], accuracy: 0.05,
                       "Hop distance drifted — is position coming from the core?")
        XCTAssertEqual(measuredStep, distances[1], accuracy: 0.05,
                       "Step distance drifted — is position coming from the core?")
    }

    func testDetectionIsRepeatableUnderNoise() {
        var hopDistances = [Double]()

        for _ in 0..<12 {
            let frames = syntheticFootFrames(noiseMetres: 0.004)
            let contacts = EventDetector().detectContacts(frames: frames)
            guard contacts.count >= 2 else { continue }
            let positions = contacts.prefix(2).compactMap {
                EventDetector.plantPosition(contact: $0.contact,
                                            frames: frames,
                                            landmark: .leftFootIndex)
            }
            guard positions.count == 2 else { continue }
            hopDistances.append(positions[1].x - positions[0].x)
        }

        XCTAssertGreaterThanOrEqual(hopDistances.count, 8)
        guard hopDistances.count >= 8 else { return }

        let mean = hopDistances.reduce(0, +) / Double(hopDistances.count)
        let variance = hopDistances
            .map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / Double(hopDistances.count)
        let sd = variance.squareRoot()

        // Well inside the 30 mm meaningful-change threshold.
        XCTAssertLessThan(sd, 0.030,
                          "Hop distance SD of \(sd * 1000) mm approaches the "
                          + "meaningful-change threshold")
    }

    func testShortSpikeIsNotACOntact() {
        let dt = ProcessingTimebase.sampleInterval
        var frames = [ReconstructedFrame]()
        for i in 0..<120 {
            let t = Double(i) * dt
            // Foot passes low but fast, as during swing. The velocity gates
            // must reject this.
            let z = i > 55 && i < 62 ? 0.01 : 0.30
            var keypoints = [PoseLandmark: Keypoint3D]()
            keypoints[.leftFootIndex] = Keypoint3D(
                position: SIMD3(Double(i) * 0.06, 0.12, z),
                confidence: 0.9, method: .sagittalPlane)
            frames.append(ReconstructedFrame(timestamp: t, frameIndex: i,
                                             keypoints: keypoints))
        }

        let contacts = EventDetector().detectContacts(frames: frames)
        XCTAssertTrue(contacts.isEmpty,
                      "A fast low pass during swing must not register as contact")
    }
}

final class ConsistencyTests: XCTestCase {

    private func key(profileID: UUID = UUID(),
                     frameRate: Int = 150,
                     pipeline: String = AnalysisPipeline.version) -> ComparabilityKey {
        ComparabilityKey(calibrationProfileID: profileID,
                         captureFingerprint: "test|back|1080x1920@150",
                         measuredFrameRate: frameRate,
                         pipelineVersion: pipeline)
    }

    func testDifferentProfilesCannotBeCompared() {
        let a = SessionRecord(athleteName: "A", key: key(),
                              metricValues: ["Hop distance": 5.3])
        let b = SessionRecord(athleteName: "A", key: key(),
                              metricValues: ["Hop distance": 5.4])

        XCTAssertThrowsError(try TrendAnalyser().compare(current: a, previous: b))
    }

    func testDifferentPipelineVersionsCannotBeCompared() {
        let id = UUID()
        let a = SessionRecord(athleteName: "A", key: key(profileID: id),
                              metricValues: ["Hop distance": 5.3])
        let b = SessionRecord(athleteName: "A",
                              key: key(profileID: id, pipeline: "0.9.0"),
                              metricValues: ["Hop distance": 5.4])

        XCTAssertThrowsError(try TrendAnalyser().compare(current: a, previous: b))
    }

    func testSmallChangesAreReportedAsNoise() throws {
        let id = UUID()
        let previous = SessionRecord(athleteName: "A", key: key(profileID: id),
                                     metricValues: ["Hop distance": 5.300,
                                                    "Contact time": 125.0])
        let current = SessionRecord(athleteName: "A", key: key(profileID: id),
                                    metricValues: ["Hop distance": 5.310,
                                                   "Contact time": 130.0])

        let comparisons = try TrendAnalyser().compare(current: current,
                                                      previous: previous)
        for comparison in comparisons {
            XCTAssertFalse(comparison.isMeaningful,
                           "\(comparison.metricName) changed by "
                           + "\(comparison.change), which is within noise")
        }
    }

    func testRealChangesAreReported() throws {
        let id = UUID()
        let previous = SessionRecord(athleteName: "A", key: key(profileID: id),
                                     metricValues: ["Hop distance": 5.300])
        let current = SessionRecord(athleteName: "A", key: key(profileID: id),
                                    metricValues: ["Hop distance": 5.450])

        let comparisons = try TrendAnalyser().compare(current: current,
                                                      previous: previous)
        XCTAssertTrue(comparisons.first?.isMeaningful ?? false,
                      "A 150 mm change must be reported as meaningful")
    }

    func testLowConfidenceWidensTheThreshold() throws {
        let id = UUID()
        let previous = SessionRecord(athleteName: "A", key: key(profileID: id),
                                     metricValues: ["Hop distance": 5.300],
                                     metricConfidences: ["Hop distance": 0.4])
        let current = SessionRecord(athleteName: "A", key: key(profileID: id),
                                    metricValues: ["Hop distance": 5.350],
                                    metricConfidences: ["Hop distance": 0.4])

        let comparisons = try TrendAnalyser().compare(current: current,
                                                      previous: previous)
        XCTAssertFalse(comparisons.first?.isMeaningful ?? true,
                       "A 50 mm change on low-confidence data should not "
                       + "clear the widened threshold")
    }
}
