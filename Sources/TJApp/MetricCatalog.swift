import Foundation

/// The display layer's description of every metric the pipeline produces.
///
/// Metric values travel through the app as `[String: Double]` on
/// `SessionRecord`, keyed by the same names `TrendAnalyser` uses for its
/// meaningful-change thresholds. That dictionary is deliberately untyped so
/// the pipeline can add a metric without a storage migration — but it means
/// nothing in the data itself says whether a value is metres, seconds or
/// degrees, or how far it can be trusted.
///
/// This catalogue supplies that. It is the single place where a metric's unit,
/// reliability tier and display order are declared, so a metric added to the
/// pipeline surfaces correctly everywhere at once rather than being formatted
/// three slightly different ways in three views.
///
/// The metric names here are exactly the keys in
/// `TrendAnalyser.meaningfulChangeThresholds`. Anything not in that table has
/// no validated noise floor, so the comparison view cannot say whether a
/// change in it is real, and it is marked accordingly.
public enum MetricCatalog {

    /// How a value should be converted for display.
    public enum Unit: Sendable {
        /// Stored in metres, shown as feet and inches.
        case distanceLarge
        /// Stored in metres, shown as inches only — quantities that are
        /// always well under a foot, where `0′ 2.4″` reads worse than `2.4″`.
        case distanceSmall
        /// Stored in seconds, shown as milliseconds.
        case time
        case velocity
        case angle
        case percentage
    }

    /// How much a number can be trusted, in the terms SETUP.md uses.
    ///
    /// This is shown in the UI rather than kept internal. A coach reading a
    /// 0.4° change in knee angle needs to know that number carries ±10–15°
    /// of absolute error, or they will coach against noise.
    public enum Tier: Int, Sendable, Comparable {
        /// ±10–20 mm. Distances and foot placement, straight off the
        /// stationary core of a contact.
        case precise = 0
        /// ±7 ms. Timing, from sub-frame-refined event boundaries.
        case timing = 1
        /// ±100 mm absolute, but considerably tighter session to session
        /// because most of the error is a fixed offset that cancels in a
        /// comparison. Heights, angles, velocities.
        case indicative = 2

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .precise:    return "±0.8″"
            case .timing:     return "±7 ms"
            case .indicative: return "Indicative"
            }
        }

        public var explanation: String {
            switch self {
            case .precise:
                return "Measured from the stationary part of the ground contact. "
                     + "Accurate to about ±0.8 inch."
            case .timing:
                return "Measured from sub-frame refined contact boundaries. "
                     + "Accurate to about ±7 ms with confirmed events."
            case .indicative:
                return "Accurate to about ±4 inches in absolute terms, but much "
                     + "tighter when comparing two sessions on the same profile, "
                     + "because most of the error is a fixed offset that cancels. "
                     + "Use the change, not the absolute value."
            }
        }
    }

    /// Display grouping, in the order the results screen shows them.
    public enum Group: Int, Sendable, CaseIterable, Comparable {
        case distances = 0
        case placement = 1
        case timing = 2
        case technique = 3

        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .distances: return "Distances"
            case .placement: return "Board and foot placement"
            case .timing:    return "Timing"
            case .technique: return "Technique"
            }
        }

        /// Whether this group belongs on the main results screen or behind
        /// the "Full analysis" disclosure.
        public var isPrimary: Bool {
            self == .distances || self == .placement || self == .timing
        }
    }

    public struct Definition: Sendable, Identifiable {
        /// Key in `SessionRecord.metricValues`.
        public let name: String
        public var id: String { name }
        public let displayName: String
        public let unit: Unit
        public let tier: Tier
        public let group: Group
        /// Sort order within the group.
        public let order: Int
        /// Whether an increase is an improvement. `nil` where it depends on
        /// the athlete's plan — phase shares have an optimal band, not a
        /// direction, and calling a rise "better" would be wrong as often as
        /// it was right.
        public let higherIsBetter: Bool?
        /// One line explaining what the number means, shown on tap.
        public let explanation: String
    }

    /// Every metric the pipeline currently emits a validated noise floor for.
    ///
    /// Note what is absent: there is no jump-phase distance. The jump lands in
    /// the pit, where the foot is occluded by the athlete's own body and the
    /// sand, and where the landing is a slide rather than a plant — so there
    /// is no stationary core to take a median over. The hop and step are
    /// measured; the jump is not, and `Hop share of measured phases` says
    /// "measured phases" rather than "total" for exactly that reason.
    /// Presenting a jump distance would mean inventing one.
    public static let all: [Definition] = [

        // --- Distances -------------------------------------------------
        Definition(name: "Hop distance",
                   displayName: "Hop",
                   unit: .distanceLarge, tier: .precise, group: .distances,
                   order: 0, higherIsBetter: true,
                   explanation: "Horizontal travel from the take-off foot plant to "
                              + "the hop landing foot plant."),

        Definition(name: "Step distance",
                   displayName: "Step",
                   unit: .distanceLarge, tier: .precise, group: .distances,
                   order: 1, higherIsBetter: true,
                   explanation: "Horizontal travel from the hop landing to the step "
                              + "landing."),

        Definition(name: "Hop share of measured phases",
                   displayName: "Hop share",
                   unit: .percentage, tier: .precise, group: .distances,
                   order: 2, higherIsBetter: nil,
                   explanation: "Hop as a percentage of hop plus step. A rising hop "
                              + "share usually means the hop is being over-driven at "
                              + "the step's expense."),

        Definition(name: "Step share of measured phases",
                   displayName: "Step share",
                   unit: .percentage, tier: .precise, group: .distances,
                   order: 3, higherIsBetter: nil,
                   explanation: "Step as a percentage of hop plus step. The step is "
                              + "the phase most often collapsed by an over-driven hop."),

        // --- Board and foot placement ----------------------------------
        Definition(name: "Toe distance behind scratch line",
                   displayName: "Board accuracy",
                   unit: .distanceSmall, tier: .precise, group: .placement,
                   order: 0, higherIsBetter: nil,
                   explanation: "How far the toe sat behind the scratch line at "
                              + "take-off. Negative means the toe was over the line — "
                              + "a foul."),

        Definition(name: "Touchdown distance ahead of hips",
                   displayName: "Touchdown ahead of hips",
                   unit: .distanceSmall, tier: .precise, group: .placement,
                   order: 1, higherIsBetter: false,
                   explanation: "How far in front of the hips the foot lands. A large "
                              + "value means the foot is reaching out ahead of the "
                              + "body, which brakes horizontal velocity."),

        // --- Timing -----------------------------------------------------
        Definition(name: "Contact time",
                   displayName: "Contact time",
                   unit: .time, tier: .timing, group: .timing,
                   order: 0, higherIsBetter: false,
                   explanation: "Time the foot spends on the ground. Shorter contacts "
                              + "generally preserve more horizontal velocity."),

        Definition(name: "Flight time",
                   displayName: "Flight time",
                   unit: .time, tier: .timing, group: .timing,
                   order: 1, higherIsBetter: true,
                   explanation: "Time in the air between contacts."),

        // --- Technique --------------------------------------------------
        Definition(name: "Approach velocity",
                   displayName: "Approach velocity",
                   unit: .velocity, tier: .indicative, group: .technique,
                   order: 0, higherIsBetter: true,
                   explanation: "Horizontal speed entering the board."),

        Definition(name: "Velocity loss",
                   displayName: "Velocity loss",
                   unit: .velocity, tier: .indicative, group: .technique,
                   order: 1, higherIsBetter: false,
                   explanation: "Horizontal speed given up across the phases. Lower "
                              + "is better: the triple jump is largely a problem of "
                              + "keeping the speed you arrived with."),

        Definition(name: "Hip rise in flight",
                   displayName: "Hip rise in flight",
                   unit: .distanceSmall, tier: .indicative, group: .technique,
                   order: 2, higherIsBetter: nil,
                   explanation: "How far the hips rise during flight. Too little is a "
                              + "flat phase; too much trades horizontal distance for "
                              + "height."),

        Definition(name: "Knee angle at touchdown",
                   displayName: "Knee angle at touchdown",
                   unit: .angle, tier: .indicative, group: .technique,
                   order: 3, higherIsBetter: nil,
                   explanation: "Knee flexion as the foot lands. Affected by about "
                              + "10% by out-of-plane motion the single camera cannot "
                              + "resolve."),

        Definition(name: "Trunk lean at touchdown",
                   displayName: "Trunk lean at touchdown",
                   unit: .angle, tier: .indicative, group: .technique,
                   order: 4, higherIsBetter: nil,
                   explanation: "Trunk angle from vertical as the foot lands. Backward "
                              + "lean at touchdown usually accompanies a braking "
                              + "contact."),
    ]

    private static let byName: [String: Definition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func definition(for name: String) -> Definition? {
        byName[name]
    }

    /// Definitions for a group, in display order.
    public static func definitions(in group: Group) -> [Definition] {
        all.filter { $0.group == group }.sorted { $0.order < $1.order }
    }

    /// Format a stored SI value for display.
    public static func format(_ value: Double, unit: Unit) -> String {
        switch unit {
        case .distanceLarge: return Imperial.feetInches(value)
        case .distanceSmall: return Imperial.inches(value)
        case .time:          return Format.milliseconds(value)
        case .velocity:      return Format.velocity(value)
        case .angle:         return Format.degrees(value)
        case .percentage:    return Format.percent(value)
        }
    }

    /// Format a change in a stored SI value, always signed.
    public static func formatChange(_ change: Double, unit: Unit) -> String {
        switch unit {
        case .distanceLarge, .distanceSmall: return Imperial.signedInches(change)
        case .time:                          return Format.signedMilliseconds(change)
        case .velocity:                      return Format.signedVelocity(change)
        case .angle:                         return Format.signedDegrees(change)
        case .percentage:                    return Format.signedPercent(change)
        }
    }

    /// The smallest change worth showing, in the metric's own stored units.
    /// Mirrors `TrendAnalyser.meaningfulChangeThresholds`, converting the
    /// millisecond entries into seconds so everything here is SI.
    public static func meaningfulChangeThreshold(for name: String) -> Double? {
        guard let raw = TrendAnalyser.meaningfulChangeThresholds[name] else {
            return nil
        }
        guard let definition = byName[name] else { return raw }
        // The threshold table quotes time in milliseconds; stored values are
        // in seconds.
        return definition.unit == .time ? raw / 1000 : raw
    }

    /// Human-readable statement of the noise floor, for the comparison view.
    public static func thresholdDescription(for name: String) -> String? {
        guard let definition = byName[name],
              let threshold = meaningfulChangeThreshold(for: name) else { return nil }
        let magnitude = formatChange(threshold, unit: definition.unit)
            .replacingOccurrences(of: "+", with: "")
        return "Changes under \(magnitude) are within measurement noise."
    }
}

/// A metric value paired with everything the UI needs to render it.
///
/// Built once when a results screen loads and passed down, so no view has to
/// reach back into the catalogue and re-derive formatting.
public struct PresentedMetric: Sendable, Identifiable {
    public let definition: MetricCatalog.Definition
    public let value: Double
    public let confidence: Double?

    public var id: String { definition.name }
    public var formattedValue: String {
        MetricCatalog.format(value, unit: definition.unit)
    }

    public init(definition: MetricCatalog.Definition,
                value: Double,
                confidence: Double? = nil) {
        self.definition = definition
        self.value = value
        self.confidence = confidence
    }

    /// Build the presentable set from a stored record, dropping any metric the
    /// catalogue does not describe.
    ///
    /// Dropping rather than showing raw is intentional: a number with no unit
    /// and no reliability tier cannot be read correctly, and a coach who sees
    /// `0.043` with no context will assume it means something.
    public static func from(record: SessionRecord) -> [PresentedMetric] {
        record.metricValues.compactMap { name, value in
            guard let definition = MetricCatalog.definition(for: name) else {
                return nil
            }
            return PresentedMetric(definition: definition,
                                   value: value,
                                   confidence: record.metricConfidences[name])
        }
        .sorted {
            $0.definition.group == $1.definition.group
                ? $0.definition.order < $1.definition.order
                : $0.definition.group < $1.definition.group
        }
    }
}
