// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// =============================================================================
// session-sentinel :: src/core/health.as
// =============================================================================
// Health zone classification and trend analysis.
//
// Storage usage is bucketed into four zones — Green, Yellow, Red, Purple —
// with configurable byte thresholds.  Trend analysis examines the last N
// readings to predict whether things are improving, stable, or degrading.
//
// The flash_check function determines whether the tray icon should blink,
// which happens only in Purple zone when storage is actively growing.
//
// Default thresholds:
//   Green  :  <= 200 MB
//   Yellow :  <= 500 MB
//   Red    :  <= 800 MB
//   Purple :  >  800 MB
// =============================================================================

module SessionSentinel.Core.Health

use SessionSentinel.Core.Config.{SizeThresholds}
use SessionSentinel.Core.Scanner.{ProviderSnapshot, Timestamp}

// ---------------------------------------------------------------------------
// Health zone
// ---------------------------------------------------------------------------

/// The four health zones, ordered by severity.
///
/// Green  — healthy: storage is well within limits.
/// Yellow — caution: storage is growing but not yet critical.
/// Red    — warning: storage is high; self-healing should be active.
/// Purple — critical: storage has breached all thresholds; aggressive
///          pruning is warranted and the tray icon flashes.
type HealthZone =
    | Green
    | Yellow
    | Red
    | Purple

/// Numeric severity for ordering and comparison.
///
/// Higher values are more severe.  Used by trend analysis to detect
/// zone transitions.
total fn zone_severity(zone: ref HealthZone) -> Nat {
    match zone {
        Green  => 0,
        Yellow => 1,
        Red    => 2,
        Purple => 3
    }
}

/// Human-readable label for display in the PanLL panel and logs.
total fn zone_label(zone: ref HealthZone) -> String {
    match zone {
        Green  => "Green (Healthy)",
        Yellow => "Yellow (Caution)",
        Red    => "Red (Warning)",
        Purple => "Purple (Critical)"
    }
}

/// Hex colour code for the tray icon and panel badge.
total fn zone_colour(zone: ref HealthZone) -> String {
    match zone {
        Green  => "#22c55e",
        Yellow => "#eab308",
        Red    => "#ef4444",
        Purple => "#a855f7"
    }
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// Classify aggregate storage usage into a health zone.
///
/// `total_bytes` is the sum across all providers.
/// `thresholds` supplies the configurable breakpoints.
///
/// The classification is inclusive on the upper bound:
///   total_bytes <= green_max   =>  Green
///   total_bytes <= yellow_max  =>  Yellow
///   total_bytes <= red_max     =>  Red
///   otherwise                  =>  Purple
total fn classify(total_bytes: Nat, thresholds: ref SizeThresholds) -> HealthZone {
    if total_bytes <= thresholds.green_max {
        Green
    } else if total_bytes <= thresholds.yellow_max {
        Yellow
    } else if total_bytes <= thresholds.red_max {
        Red
    } else {
        Purple
    }
}

/// Classify a single provider snapshot in isolation.
///
/// Useful for per-provider health badges in the PanLL panel.
total fn classify_provider(
    snapshot: ref ProviderSnapshot,
    thresholds: ref SizeThresholds
) -> HealthZone {
    classify(snapshot.total_bytes, thresholds)
}

// ---------------------------------------------------------------------------
// Historical reading
// ---------------------------------------------------------------------------

/// A single historical data point: a timestamp and the total bytes at
/// that point.
///
/// The monitor stores a ring buffer of these (typically last 100) and
/// feeds them to the trend analyser.
type HealthReading = {
    /// When the reading was taken (UNIX seconds).
    timestamp: Timestamp,

    /// Aggregate bytes across all providers at that time.
    total_bytes: Nat,

    /// The zone that was assigned.
    zone: HealthZone
}

// ---------------------------------------------------------------------------
// Trend analysis
// ---------------------------------------------------------------------------

/// Describes the direction in which storage usage is moving.
type TrendDirection =
    /// Usage is shrinking (self-healing is effective, or user cleaned up).
    | Improving
    /// Usage is roughly flat (within a +/- 5% band).
    | Stable
    /// Usage is growing and may soon cross a zone boundary.
    | Degrading

/// Full trend analysis result.
type TrendAnalysis = {
    /// Current direction of travel.
    direction: TrendDirection,

    /// Predicted zone if the current trend continues for one more scan
    /// interval.  `None` when there are fewer than 2 readings.
    predicted_zone: Option[HealthZone],

    /// Average bytes-per-second growth rate (negative means shrinking).
    /// Computed via simple linear regression over the readings.
    growth_rate_bps: Int,

    /// Number of readings used for the analysis.
    sample_count: Nat
}

/// Analyse a list of historical readings and produce a trend result.
///
/// Requires at least 2 readings to compute a direction; with fewer,
/// returns `Stable` with no prediction.
///
/// The growth rate is computed via least-squares linear regression on
/// `(timestamp, total_bytes)` pairs.
total fn analyse_trend(
    readings:   ref Vec[HealthReading],
    thresholds: ref SizeThresholds,
    scan_interval_secs: Nat
) -> TrendAnalysis {
    let n = readings.len();

    if n < 2 {
        return {
            direction:      Stable,
            predicted_zone: None,
            growth_rate_bps: 0,
            sample_count:   n
        }
    };

    // --- Linear regression: y = a + b*x  where x=timestamp, y=total_bytes ---
    let sum_x:  Int = readings.iter().fold(0, |acc, r| acc + r.timestamp as Int);
    let sum_y:  Int = readings.iter().fold(0, |acc, r| acc + r.total_bytes as Int);
    let sum_xy: Int = readings.iter().fold(0, |acc, r|
        acc + (r.timestamp as Int) * (r.total_bytes as Int)
    );
    let sum_xx: Int = readings.iter().fold(0, |acc, r|
        acc + (r.timestamp as Int) * (r.timestamp as Int)
    );

    let n_int = n as Int;
    let denominator = n_int * sum_xx - sum_x * sum_x;

    // Avoid division by zero (all readings at the same timestamp).
    let slope: Int = if denominator == 0 {
        0
    } else {
        (n_int * sum_xy - sum_x * sum_y) / denominator
    };

    // --- Classify direction ---
    // "Stable" if the absolute growth rate is less than 5% of the latest
    // reading per scan interval.
    let latest_bytes = readings.last().map(|r| r.total_bytes).unwrap_or(0);
    let stability_band = (latest_bytes as Int) * 5 / 100;
    let growth_per_interval = slope * (scan_interval_secs as Int);

    let direction = if growth_per_interval > stability_band {
        Degrading
    } else if growth_per_interval < -stability_band {
        Improving
    } else {
        Stable
    };

    // --- Predict next zone ---
    let predicted_bytes = (latest_bytes as Int) + growth_per_interval;
    let predicted_bytes_nat = if predicted_bytes < 0 { 0 } else { predicted_bytes as Nat };
    let predicted_zone = Some(classify(predicted_bytes_nat, thresholds));

    {
        direction:       direction,
        predicted_zone:  predicted_zone,
        growth_rate_bps: slope,
        sample_count:    n
    }
}

// ---------------------------------------------------------------------------
// Flash check
// ---------------------------------------------------------------------------

/// Determine whether the system tray icon should flash.
///
/// The icon flashes when **both** conditions are met:
///   1. The current zone is Purple (critical).
///   2. The trend direction is Degrading (storage is still growing).
///
/// This avoids flashing when the healer has successfully brought storage
/// under control even though we are still in Purple.
total fn flash_check(zone: ref HealthZone, trend: ref TrendAnalysis) -> Bool {
    match (zone, trend.direction) {
        (Purple, Degrading) => true,
        _                   => false
    }
}

// ---------------------------------------------------------------------------
// Zone transition detection
// ---------------------------------------------------------------------------

/// Detect whether a zone transition has occurred between two readings.
///
/// Returns `Some((old_zone, new_zone))` when they differ, `None` when
/// they are the same.  Used to trigger notifications and log entries.
total fn detect_transition(
    previous: ref HealthZone,
    current:  ref HealthZone
) -> Option[(HealthZone, HealthZone)] {
    if zone_severity(previous) == zone_severity(current) {
        None
    } else {
        Some((previous.clone(), current.clone()))
    }
}

/// Returns `true` when the transition is an escalation (moving to a
/// more severe zone).
total fn is_escalation(previous: ref HealthZone, current: ref HealthZone) -> Bool {
    zone_severity(current) > zone_severity(previous)
}

/// Returns `true` when the transition is a de-escalation (moving to a
/// less severe zone).
total fn is_deescalation(previous: ref HealthZone, current: ref HealthZone) -> Bool {
    zone_severity(current) < zone_severity(previous)
}

// ---------------------------------------------------------------------------
// Composite health summary
// ---------------------------------------------------------------------------

/// All-in-one health summary produced once per scan cycle.
///
/// This is the primary data structure pushed to the PanLL panel over
/// the Unix socket.
type HealthSummary = {
    /// The current health zone.
    zone: HealthZone,

    /// Per-provider zones (provider name -> zone).
    provider_zones: Vec[(String, HealthZone)],

    /// Aggregate bytes across all providers.
    total_bytes: Nat,

    /// Trend analysis from the historical ring buffer.
    trend: TrendAnalysis,

    /// Whether the tray icon should flash.
    should_flash: Bool,

    /// Zone transition since last scan, if any.
    transition: Option[(HealthZone, HealthZone)],

    /// Timestamp of this summary.
    timestamp: Timestamp
}

/// Build a complete health summary from the latest scan results and
/// historical readings.
total fn build_summary(
    snapshots:     ref Vec[ProviderSnapshot],
    readings:      ref Vec[HealthReading],
    previous_zone: ref HealthZone,
    thresholds:    ref SizeThresholds,
    scan_interval: Nat,
    now:           Timestamp
) -> HealthSummary {
    let total = snapshots.iter().fold(0, |acc, s| acc + s.total_bytes);
    let zone  = classify(total, thresholds);
    let trend = analyse_trend(readings, thresholds, scan_interval);

    let provider_zones = snapshots.iter().map(|s|
        (s.provider_name.clone(), classify(s.total_bytes, thresholds))
    ).collect();

    {
        zone:           zone.clone(),
        provider_zones: provider_zones,
        total_bytes:    total,
        trend:          trend.clone(),
        should_flash:   flash_check(ref zone, ref trend),
        transition:     detect_transition(previous_zone, ref zone),
        timestamp:      now
    }
}
