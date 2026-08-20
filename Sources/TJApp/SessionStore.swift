import Foundation

/// A Codable snapshot of one detected ground event.
///
/// `GroundEvent` carries a freshly-generated `id` and is not itself Codable;
/// giving it synthesised conformance would silently regenerate that id on
/// every decode, so a user who confirmed an event on Monday would find the
/// confirmation attached to a different identity on Tuesday. This DTO owns a
/// stable id instead, and the core type stays untouched.
public struct EventSnapshot: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var type: EventType
    public var timestamp: Double
    public var frameIndex: Int
    public var side: GroundEvent.Side
    public var confidence: Double
    public var isManuallyConfirmed: Bool

    /// Where the detector originally put this event, kept for the whole life
    /// of the session so a correction can always be reverted and so the
    /// difference between automatic and confirmed placement stays auditable.
    public var detectedFrameIndex: Int
    public var detectedTimestamp: Double

    /// True when the user created this event by hand because the detector
    /// missed a contact entirely.
    public var isUserCreated: Bool

    public init(id: UUID = UUID(),
                type: EventType,
                timestamp: Double,
                frameIndex: Int,
                side: GroundEvent.Side,
                confidence: Double,
                isManuallyConfirmed: Bool = false,
                detectedFrameIndex: Int? = nil,
                detectedTimestamp: Double? = nil,
                isUserCreated: Bool = false) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.side = side
        self.confidence = confidence
        self.isManuallyConfirmed = isManuallyConfirmed
        self.detectedFrameIndex = detectedFrameIndex ?? frameIndex
        self.detectedTimestamp = detectedTimestamp ?? timestamp
        self.isUserCreated = isUserCreated
    }

    public init(_ event: GroundEvent) {
        self.init(type: event.type,
                  timestamp: event.timestamp,
                  frameIndex: event.frameIndex,
                  side: event.side,
                  confidence: event.confidence,
                  isManuallyConfirmed: event.isManuallyConfirmed)
    }

    public var groundEvent: GroundEvent {
        GroundEvent(type: type,
                    timestamp: timestamp,
                    frameIndex: frameIndex,
                    side: side,
                    confidence: confidence,
                    isManuallyConfirmed: isManuallyConfirmed)
    }

    /// True when the user has moved this event away from where the detector
    /// put it.
    public var isMoved: Bool { frameIndex != detectedFrameIndex }

    /// Events below this confidence are surfaced for review. Matches the
    /// threshold `PhaseSegmentation.requiresManualReview` already uses, so
    /// the review prompt and the per-event flags agree.
    public static let reviewConfidenceThreshold: Double = 0.7

    public var needsReview: Bool {
        !isManuallyConfirmed && confidence < Self.reviewConfidenceThreshold
    }
}

/// A Codable snapshot of one segmented phase.
public struct PhaseSnapshot: Codable, Identifiable, Sendable, Equatable {
    public var id: String { "\(phase.rawValue)-\(startFrame)" }
    public var phase: JumpPhase
    public var startTime: Double
    public var endTime: Double
    public var startFrame: Int
    public var endFrame: Int
    public var side: GroundEvent.Side?
    public var confidence: Double

    public var duration: Double { endTime - startTime }

    public init(_ phase: PhaseSegmentation.Phase) {
        self.phase = phase.phase
        self.startTime = phase.startTime
        self.endTime = phase.endTime
        self.startFrame = phase.startFrame
        self.endFrame = phase.endFrame
        self.side = phase.side
        self.confidence = phase.confidence
    }
}

/// The analysis output for one jump, stored independently of the video.
///
/// This is the part that must survive forever. It is small — a few kilobytes
/// of events, phases and metric values — where the video it came from is
/// hundreds of megabytes. Separating them is what makes the retention policy
/// possible: the footage can be dropped without losing the season's history.
public struct SessionAnalysis: Codable, Sendable {
    public var events: [EventSnapshot]
    public var phases: [PhaseSnapshot]
    public var segmentationConfidence: Double
    public var warnings: [String]

    /// Frame count and rate of the source recording, retained so the
    /// correction screen can still show a timeline after the video is gone,
    /// and so a re-analysis knows the timebase it is working against.
    public var frameCount: Int
    public var measuredFrameRate: Double

    /// Timestamp of the first sample on this session's analysis grid.
    ///
    /// Two frame numberings are in play and they are not interchangeable.
    /// `EventSnapshot.frameIndex` counts the analysis grid, which is what
    /// `PhaseSegmenter` matches against; the video player counts source
    /// frames, which arrive at whatever rate the camera managed. Timestamps
    /// are the only quantity common to both, and converting between the two
    /// numberings needs this origin. Without it, an event confirmed against
    /// the video would be written back at the wrong place on the grid.
    ///
    /// The grid rate itself is not stored separately — it is not a fixed
    /// 150 Hz constant any more, but derived the same way every time from
    /// `measuredFrameRate` by `analysisFrameIndex(forTime:)` below, so it
    /// never needs to agree with anything except itself.
    public var analysisStartTime: Double

    public init(events: [EventSnapshot],
                phases: [PhaseSnapshot],
                segmentationConfidence: Double,
                warnings: [String],
                frameCount: Int,
                measuredFrameRate: Double,
                analysisStartTime: Double = 0) {
        self.events = events
        self.phases = phases
        self.segmentationConfidence = segmentationConfidence
        self.warnings = warnings
        self.frameCount = frameCount
        self.measuredFrameRate = measuredFrameRate
        self.analysisStartTime = analysisStartTime
    }

    public init(segmentation: PhaseSegmentation,
                events: [GroundEvent],
                frameCount: Int,
                measuredFrameRate: Double,
                analysisStartTime: Double = 0) {
        self.events = events.map(EventSnapshot.init)
        self.phases = segmentation.phases.map(PhaseSnapshot.init)
        self.segmentationConfidence = segmentation.overallConfidence
        self.warnings = segmentation.warnings
        self.frameCount = frameCount
        self.measuredFrameRate = measuredFrameRate
        self.analysisStartTime = analysisStartTime
    }

    /// Analysis-grid index for a timestamp.
    ///
    /// Deliberately does not read the live `ProcessingTimebase.analysisRate`.
    /// That value is mutable and reconfigured at the start of every analysis
    /// run — reading it here, from a correction screen that can be opened
    /// days after the session it belongs to was analysed, would silently use
    /// whatever *unrelated* session was analysed most recently instead of
    /// this one. Deriving the rate from this session's own stored
    /// `measuredFrameRate`, through the same pure clamp `configure` used, is
    /// what makes this correct regardless of what has happened globally
    /// since.
    public func analysisFrameIndex(forTime time: Double) -> Int {
        let rate = ProcessingTimebase.clampedRate(forDelivered: measuredFrameRate)
        return max(Int(((time - analysisStartTime) * rate).rounded()), 0)
    }

    public var allEventsConfirmed: Bool {
        !events.isEmpty && events.allSatisfy(\.isManuallyConfirmed)
    }

    public var eventsNeedingReview: [EventSnapshot] {
        events.filter(\.needsReview)
    }
}

// MARK: - Video retention

/// What has happened to a session's footage.
///
/// Video is kept for three days and then dropped unless the user has asked to
/// keep it. The reasoning is a straight storage trade: a 240 fps recording of
/// a single jump runs to several hundred megabytes, and a squad of eight
/// athletes taking six trials a session fills a phone in a fortnight. The
/// analysis is what the tool exists to produce and it costs kilobytes, so it
/// is never dropped.
///
/// Three days rather than one: a coach who records on Friday should still be
/// able to review footage with the athlete at Monday training.
public enum VideoRetention: Codable, Sendable, Equatable {

    /// Footage on disk, scheduled for automatic removal.
    case temporary(expiresAt: Date)

    /// User asked to keep this one. Never removed automatically.
    case keptByUser

    /// Footage has been removed. The analysis remains.
    case dropped(at: Date)

    /// Footage was never written, or was removed outside the app.
    case unavailable

    public var hasVideo: Bool {
        switch self {
        case .temporary, .keptByUser: return true
        case .dropped, .unavailable:  return false
        }
    }

    public var expiryDate: Date? {
        if case .temporary(let date) = self { return date }
        return nil
    }
}

/// How long footage survives without an explicit keep.
public enum RetentionPolicy {

    public static let temporaryVideoDays: Int = 3

    /// Warn the user in the UI once footage is inside this window, so the
    /// choice to keep it is made before the file is gone rather than
    /// discovered afterwards.
    public static let warnWithinDays: Int = 1

    public static func expiryDate(from date: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day,
                              value: temporaryVideoDays,
                              to: date) ?? date.addingTimeInterval(259_200)
    }

    /// Whole days remaining before footage is dropped, floored at zero.
    public static func daysRemaining(until expiry: Date,
                                     now: Date = Date()) -> Int {
        max(Calendar.current.dateComponents([.day], from: now, to: expiry).day ?? 0, 0)
    }
}

// MARK: - Stored session

/// One recorded jump: the comparable record, the analysis, and whatever is
/// left of the footage.
public struct StoredSession: Codable, Identifiable, Sendable {

    public var record: SessionRecord
    public var analysis: SessionAnalysis
    public var retention: VideoRetention

    /// Where the footage lives, relative to the sessions directory rather
    /// than absolute. iOS reassigns the application container path on
    /// reinstall and on some OS upgrades, so an absolute URL stored today can
    /// be dangling tomorrow while the file itself is perfectly intact.
    public var videoFilename: String?

    /// Trial number within the day's session, so six jumps by one athlete on
    /// one afternoon are distinguishable at a glance.
    public var trialNumber: Int

    public var id: UUID { record.id }
    public var athleteName: String { record.athleteName }
    public var date: Date { record.date }

    public init(record: SessionRecord,
                analysis: SessionAnalysis,
                retention: VideoRetention,
                videoFilename: String? = nil,
                trialNumber: Int = 1) {
        self.record = record
        self.analysis = analysis
        self.retention = retention
        self.videoFilename = videoFilename
        self.trialNumber = trialNumber
    }

    public var eventsConfirmed: Bool { analysis.allEventsConfirmed }

    /// Whether this session can still be opened in the event correction
    /// screen with video. Once footage is gone the events are frozen: there
    /// is no honest way to confirm a contact you cannot look at.
    public var canCorrectEvents: Bool { retention.hasVideo }
}

// MARK: - Store

public enum SessionStoreError: Error, LocalizedError {
    case videoMissing
    case sessionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .videoMissing:
            return "The recording for this session is no longer on the device."
        case .sessionNotFound(let id):
            return "No session found with id \(id.uuidString)."
        }
    }
}

/// On-device storage for sessions.
///
/// Mirrors `CalibrationProfileStore`: an actor over a directory of JSON files,
/// one per session, with the video alongside. Files rather than a database
/// because a session is written once and read whole, there is no query beyond
/// "all of them sorted by date", and a corrupt file costs one jump instead of
/// the entire history.
public actor SessionStore {

    private let directory: URL
    private let videosDirectory: URL
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
            self.directory = base.appendingPathComponent("Sessions", isDirectory: true)
        }
        self.videosDirectory = self.directory.appendingPathComponent("Video",
                                                                     isDirectory: true)

        try FileManager.default.createDirectory(at: self.directory,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.videosDirectory,
                                                withIntermediateDirectories: true)

        // Footage is the user's own training material and must not be handed
        // to iCloud backup: it is large, it is regenerable by re-recording,
        // and a squad's worth would swamp a backup allowance.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var videosURL = self.videosDirectory
        try? videosURL.setResourceValues(resourceValues)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Where the archived 2D pose for a session lives.
    ///
    /// Internal rather than private so `AnalysisRunner`'s archive extension
    /// can reach it. It sits beside the session JSON rather than under
    /// `Video/`, because it must survive the retention sweep that removes
    /// footage — re-analysis after the video is gone depends on it.
    public func poseArchiveURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).pose.json")
    }

    public func videoURL(for session: StoredSession) -> URL? {
        guard let filename = session.videoFilename, session.retention.hasVideo else {
            return nil
        }
        let url = videosDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Destination for a new recording, before analysis has run.
    public func reserveVideoURL(for id: UUID) -> (url: URL, filename: String) {
        let filename = "\(id.uuidString).mov"
        return (videosDirectory.appendingPathComponent(filename), filename)
    }

    public func save(_ session: StoredSession) throws {
        try encoder.encode(session).write(to: url(for: session.id), options: .atomic)
    }

    public func load(id: UUID) throws -> StoredSession {
        try decoder.decode(StoredSession.self, from: Data(contentsOf: url(for: id)))
    }

    /// Every session, newest first.
    public func loadAll() throws -> [StoredSession] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return files
            // Pose archives are `<uuid>.pose.json` and so also end in "json".
            // Excluding them by name rather than relying on the decode below
            // to fail: a silent decode failure is indistinguishable from a
            // corrupt session file, and this directory contains both kinds.
            .filter { $0.pathExtension == "json"
                      && !$0.lastPathComponent.hasSuffix(".pose.json") }
            .compactMap { try? decoder.decode(StoredSession.self,
                                              from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    /// Next trial number for an athlete on a given day.
    public func nextTrialNumber(athlete: String, on day: Date) throws -> Int {
        let calendar = Calendar.current
        let existing = try loadAll().filter {
            $0.athleteName == athlete && calendar.isDate($0.date, inSameDayAs: day)
        }
        return (existing.map(\.trialNumber).max() ?? 0) + 1
    }

    // MARK: Retention

    /// Mark footage as permanent.
    public func keepVideo(id: UUID) throws {
        var session = try load(id: id)
        guard session.retention.hasVideo else { throw SessionStoreError.videoMissing }
        session.retention = .keptByUser
        try save(session)
    }

    /// Release footage back to the automatic three-day clock, measured from
    /// now rather than from the original recording date — a user who keeps a
    /// clip and then changes their mind should get the full window back, not
    /// an already-expired one.
    public func releaseVideo(id: UUID) throws {
        var session = try load(id: id)
        guard session.retention.hasVideo else { return }
        session.retention = .temporary(expiresAt: RetentionPolicy.expiryDate())
        try save(session)
    }

    /// Drop one session's footage immediately, keeping the analysis.
    @discardableResult
    public func dropVideo(id: UUID) throws -> StoredSession {
        var session = try load(id: id)
        if let filename = session.videoFilename {
            let url = videosDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        session.retention = .dropped(at: Date())
        session.record.videoURL = nil
        try save(session)
        return session
    }

    /// What a prune would remove. The UI calls this to warn before anything
    /// is deleted, and the caller decides whether to proceed.
    public func videosExpiringSoon(now: Date = Date()) throws -> [StoredSession] {
        try loadAll().filter { session in
            guard let expiry = session.retention.expiryDate else { return false }
            return RetentionPolicy.daysRemaining(until: expiry, now: now)
                <= RetentionPolicy.warnWithinDays
        }
    }

    /// Remove footage past its expiry, keeping every analysis.
    ///
    /// Returns the sessions whose footage was dropped so the caller can tell
    /// the user what happened. Silent deletion of a coach's footage would be
    /// indistinguishable from a bug.
    @discardableResult
    public func pruneExpiredVideos(now: Date = Date()) throws -> [StoredSession] {
        var dropped = [StoredSession]()
        for session in try loadAll() {
            guard case .temporary(let expiry) = session.retention,
                  expiry <= now else { continue }
            dropped.append(try dropVideo(id: session.id))
        }
        return dropped
    }

    /// Total bytes currently held by footage, for a storage row in settings.
    public func videoBytesOnDisk() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: videosDirectory,
            includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }

    // MARK: Event correction

    /// Persist corrected events and the segmentation they produced.
    ///
    /// Confirmed events are the point of the whole correction screen: an
    /// automatic detection can land a frame or two differently between
    /// sessions, where a confirmed one is identical every time. Once written
    /// they are treated as settled, and a later pipeline version re-analyses
    /// *from* them rather than re-detecting over the top.
    public func updateAnalysis(id: UUID,
                               events: [EventSnapshot],
                               segmentation: PhaseSegmentation,
                               metricValues: [String: Double],
                               metricConfidences: [String: Double]) throws {
        var session = try load(id: id)
        session.analysis.events = events
        session.analysis.phases = segmentation.phases.map(PhaseSnapshot.init)
        session.analysis.segmentationConfidence = segmentation.overallConfidence
        session.analysis.warnings = segmentation.warnings
        session.record.metricValues = metricValues
        session.record.metricConfidences = metricConfidences
        session.record.eventsManuallyConfirmed = events.allSatisfy(\.isManuallyConfirmed)
        try save(session)
    }

    public func delete(id: UUID) throws {
        let session = try? load(id: id)
        if let filename = session?.videoFilename {
            try? FileManager.default.removeItem(
                at: videosDirectory.appendingPathComponent(filename))
        }
        try? FileManager.default.removeItem(at: poseArchiveURL(for: id))
        try FileManager.default.removeItem(at: url(for: id))
    }
}
