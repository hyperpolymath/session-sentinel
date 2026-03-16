-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Monitor Protocol — Commands, Responses, and Fault Tolerance
|||
||| This module defines the wire protocol between the session-sentinel
||| daemon and its clients (system tray, PanLL panels, CLI tools).
|||
||| Key contracts enforced at the type level:
|||   - Self-healing: if the zone is Red or Purple and autoHeal is on,
|||     the system MUST produce a HealingAction (not just a report).
|||   - Fault tolerance: the WatchdogState machine requires explicit
|||     recovery — a Failed watchdog cannot silently become Healthy.
|||   - Provider exhaustiveness: all known AI providers have mandatory
|||     configuration fields.
|||
||| @see SessionSentinel.ABI.HealthState for zone definitions
||| @see SessionSentinel.ABI.PanelProtocol for PanLL integration

module SessionSentinel.ABI.MonitorProtocol

import SessionSentinel.ABI.HealthState
import Data.Nat
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- AI Provider Identification
--------------------------------------------------------------------------------

||| Supported AI session providers that the monitor can scan.
|||
||| Each variant corresponds to a known provider with predictable
||| storage layout. CustomProvider accommodates unknown or future providers.
public export
data AIProvider : Type where
  ||| Anthropic Claude — ~/.claude/ session storage
  Claude     : AIProvider
  ||| GitHub Copilot — ~/.config/github-copilot/ and workspace dirs
  Copilot    : AIProvider
  ||| Ollama local models — ~/.ollama/ model and session data
  Ollama     : AIProvider
  ||| LM Studio — ~/.cache/lm-studio/ session storage
  LMStudio   : AIProvider
  ||| Any provider not in the built-in list, identified by name string
  CustomProvider : (name : String) -> AIProvider

||| Decidable equality for AIProvider.
||| CustomProvider equality is based on string name comparison.
public export
DecEq AIProvider where
  decEq Claude     Claude     = Yes Refl
  decEq Copilot    Copilot    = Yes Refl
  decEq Ollama     Ollama     = Yes Refl
  decEq LMStudio   LMStudio   = Yes Refl
  decEq (CustomProvider n1) (CustomProvider n2) =
    case decEq n1 n2 of
      Yes Refl => Yes Refl
      No contra => No (\case Refl => contra Refl)
  decEq Claude     Copilot           = No (\case Refl impossible)
  decEq Claude     Ollama            = No (\case Refl impossible)
  decEq Claude     LMStudio          = No (\case Refl impossible)
  decEq Claude     (CustomProvider _) = No (\case Refl impossible)
  decEq Copilot    Claude            = No (\case Refl impossible)
  decEq Copilot    Ollama            = No (\case Refl impossible)
  decEq Copilot    LMStudio          = No (\case Refl impossible)
  decEq Copilot    (CustomProvider _) = No (\case Refl impossible)
  decEq Ollama     Claude            = No (\case Refl impossible)
  decEq Ollama     Copilot           = No (\case Refl impossible)
  decEq Ollama     LMStudio          = No (\case Refl impossible)
  decEq Ollama     (CustomProvider _) = No (\case Refl impossible)
  decEq LMStudio   Claude            = No (\case Refl impossible)
  decEq LMStudio   Copilot           = No (\case Refl impossible)
  decEq LMStudio   Ollama            = No (\case Refl impossible)
  decEq LMStudio   (CustomProvider _) = No (\case Refl impossible)
  decEq (CustomProvider _) Claude    = No (\case Refl impossible)
  decEq (CustomProvider _) Copilot   = No (\case Refl impossible)
  decEq (CustomProvider _) Ollama    = No (\case Refl impossible)
  decEq (CustomProvider _) LMStudio  = No (\case Refl impossible)

||| Eq instance for AIProvider, derived from DecEq.
public export
Eq AIProvider where
  p1 == p2 = case decEq p1 p2 of
    Yes _ => True
    No _  => False

||| Show instance for AIProvider, producing display-friendly names.
public export
Show AIProvider where
  show Claude              = "Claude"
  show Copilot             = "Copilot"
  show Ollama              = "Ollama"
  show LMStudio            = "LMStudio"
  show (CustomProvider n)  = "Custom(" ++ n ++ ")"

--------------------------------------------------------------------------------
-- Provider Configuration
--------------------------------------------------------------------------------

||| Configuration for monitoring a specific AI provider's sessions.
|||
||| Each provider may have multiple storage paths (e.g., config dir
||| plus workspace-local dirs). The scan interval and staleness
||| threshold are per-provider to accommodate different usage patterns.
|||
||| @param provider        Which AI provider this config applies to
||| @param storagePaths    List of filesystem paths to scan (non-empty)
||| @param staleDays       Number of days after which a session is "stale"
||| @param scanIntervalSecs Seconds between scan passes for this provider
public export
record ProviderConfig where
  constructor MkProviderConfig
  ||| The AI provider this configuration targets
  provider         : AIProvider
  ||| Filesystem paths to scan for session data (must be non-empty)
  storagePaths     : List String
  ||| Days after which a session artifact is considered stale
  staleDays        : Nat
  ||| Seconds between consecutive scan passes
  scanIntervalSecs : Nat

||| Show instance for ProviderConfig.
public export
Show ProviderConfig where
  show c = "ProviderConfig{"
        ++ "provider=" ++ show c.provider
        ++ ", paths=" ++ show c.storagePaths
        ++ ", staleDays=" ++ show c.staleDays
        ++ ", interval=" ++ show c.scanIntervalSecs ++ "s"
        ++ "}"

--------------------------------------------------------------------------------
-- Per-Provider Snapshot
--------------------------------------------------------------------------------

||| A snapshot of one provider's health at a point in time.
|||
||| Produced during a scan pass, capturing both the raw metrics
||| and the classified zone for that individual provider.
public export
record ProviderSnapshot where
  constructor MkProviderSnapshot
  ||| Which provider this snapshot describes
  provider : AIProvider
  ||| Raw storage metrics for this provider
  metrics  : StorageMetrics
  ||| Classified health zone for this provider
  zone     : HealthZone

||| Show instance for ProviderSnapshot.
public export
Show ProviderSnapshot where
  show s = "ProviderSnapshot{"
        ++ show s.provider
        ++ ", zone=" ++ show s.zone
        ++ ", " ++ show s.metrics
        ++ "}"

--------------------------------------------------------------------------------
-- Trend Direction
--------------------------------------------------------------------------------

||| Direction of health trend over recent scan history.
|||
||| Computed by comparing the last N scan results to determine
||| whether overall health is getting better, worse, or holding steady.
public export
data TrendDirection : Type where
  ||| Health metrics are improving (zone severity decreasing)
  Improving : TrendDirection
  ||| Health metrics are stable (no significant change)
  Stable    : TrendDirection
  ||| Health metrics are worsening (zone severity increasing)
  Degrading : TrendDirection

||| Eq instance for TrendDirection.
public export
Eq TrendDirection where
  Improving == Improving = True
  Stable    == Stable    = True
  Degrading == Degrading = True
  _         == _         = False

||| Show instance for TrendDirection.
public export
Show TrendDirection where
  show Improving = "Improving"
  show Stable    = "Stable"
  show Degrading = "Degrading"

--------------------------------------------------------------------------------
-- Health Report
--------------------------------------------------------------------------------

||| Comprehensive health report produced after a scan pass.
|||
||| Aggregates per-provider snapshots into an overall zone assessment.
||| The overall zone is the worst (highest severity) zone among all
||| provider snapshots — the system is only as healthy as its weakest link.
|||
||| @param zone           Aggregate health zone (worst of all providers)
||| @param metrics        Aggregate storage metrics (summed across providers)
||| @param providers      Per-provider health snapshots
||| @param timestamp      Unix epoch seconds when this report was generated
||| @param trendDirection Whether health is improving, stable, or degrading
public export
record HealthReport where
  constructor MkHealthReport
  ||| Overall health zone (worst across all providers)
  zone           : HealthZone
  ||| Aggregate storage metrics (sum of all provider metrics)
  metrics        : StorageMetrics
  ||| Individual provider snapshots contributing to this report
  providers      : List ProviderSnapshot
  ||| Unix epoch seconds when this scan completed
  timestamp      : Nat
  ||| Trend direction based on recent scan history
  trendDirection : TrendDirection

||| Show instance for HealthReport.
public export
Show HealthReport where
  show r = "HealthReport{"
        ++ "zone=" ++ show r.zone
        ++ ", trend=" ++ show r.trendDirection
        ++ ", " ++ show r.metrics
        ++ ", providers=" ++ show (length r.providers)
        ++ ", t=" ++ show r.timestamp
        ++ "}"

--------------------------------------------------------------------------------
-- Monitor Commands
--------------------------------------------------------------------------------

||| Commands that can be sent to the session-sentinel monitor daemon.
|||
||| Each command triggers a specific workflow in the daemon and produces
||| a corresponding MonitorResponse variant.
public export
data MonitorCommand : Type where
  ||| Trigger an immediate scan of all configured providers.
  ||| Response: HealthReport
  Scan      : MonitorCommand
  ||| Attempt to heal session storage (clean orphans, archive stale files).
  ||| Response: HealingReport
  Heal      : MonitorCommand
  ||| Run detailed diagnostics on a specific provider.
  ||| Response: DiagnosticReport
  Diagnose  : (target : AIProvider) -> MonitorCommand
  ||| Update monitor configuration (thresholds, providers, intervals).
  ||| Response: Ack or Error
  Configure : (configs : List ProviderConfig) -> MonitorCommand
  ||| Gracefully shut down the monitor daemon.
  ||| Response: Ack
  Shutdown  : MonitorCommand

||| Show instance for MonitorCommand.
public export
Show MonitorCommand where
  show Scan           = "Scan"
  show Heal           = "Heal"
  show (Diagnose p)   = "Diagnose(" ++ show p ++ ")"
  show (Configure cs) = "Configure(" ++ show (length cs) ++ " providers)"
  show Shutdown       = "Shutdown"

--------------------------------------------------------------------------------
-- Healing Actions
--------------------------------------------------------------------------------

||| Specific healing actions that can be taken to restore health.
public export
data HealingAction : Type where
  ||| Remove orphaned files that have no parent session
  CleanOrphans     : (count : Nat) -> (bytesFreed : Nat) -> HealingAction
  ||| Archive stale sessions beyond the staleness threshold
  ArchiveStale     : (count : Nat) -> (bytesArchived : Nat) -> HealingAction
  ||| Compact conversation storage by deduplicating
  CompactStorage   : (bytesRecovered : Nat) -> HealingAction
  ||| Provider-specific cleanup (e.g., clearing model cache)
  ProviderCleanup  : (provider : AIProvider) -> (detail : String) -> HealingAction

||| Show instance for HealingAction.
public export
Show HealingAction where
  show (CleanOrphans c b)     = "CleanOrphans(n=" ++ show c ++ ", freed=" ++ show b ++ ")"
  show (ArchiveStale c b)     = "ArchiveStale(n=" ++ show c ++ ", archived=" ++ show b ++ ")"
  show (CompactStorage b)     = "CompactStorage(recovered=" ++ show b ++ ")"
  show (ProviderCleanup p d)  = "ProviderCleanup(" ++ show p ++ ", " ++ d ++ ")"

--------------------------------------------------------------------------------
-- Monitor Responses
--------------------------------------------------------------------------------

||| Responses produced by the monitor in reply to MonitorCommands.
|||
||| Each variant corresponds to a specific command type, ensuring
||| that callers can pattern-match on the expected response shape.
public export
data MonitorResponse : Type where
  ||| Result of a Scan command: full health report
  HealthReportResponse    : HealthReport -> MonitorResponse
  ||| Result of a Heal command: list of actions taken and resulting health
  HealingReportResponse   : (actions : List HealingAction)
                         -> (resultingHealth : HealthReport)
                         -> MonitorResponse
  ||| Result of a Diagnose command: provider-specific diagnostic text
  DiagnosticReportResponse : (provider : AIProvider)
                          -> (snapshot : ProviderSnapshot)
                          -> (details : List String)
                          -> MonitorResponse
  ||| Acknowledgment of a successful Configure or Shutdown command
  AckResponse             : (message : String) -> MonitorResponse
  ||| Error response for any command that failed
  ErrorResponse           : (message : String) -> MonitorResponse

||| Show instance for MonitorResponse.
public export
Show MonitorResponse where
  show (HealthReportResponse r)          = "HealthReport:" ++ show r
  show (HealingReportResponse as r)      = "HealingReport:" ++ show (length as) ++ " actions"
  show (DiagnosticReportResponse p s ds) = "Diagnostic:" ++ show p
  show (AckResponse msg)                 = "Ack:" ++ msg
  show (ErrorResponse msg)               = "Error:" ++ msg

--------------------------------------------------------------------------------
-- Self-Healing Contract
--------------------------------------------------------------------------------

||| Evidence that auto-healing is enabled in the monitor configuration.
public export
data AutoHealEnabled : Type where
  ||| Auto-heal is switched on
  AutoHealOn : AutoHealEnabled

||| Evidence that a zone requires healing intervention.
|||
||| Only Red and Purple zones are eligible for automatic healing.
||| Green and Yellow zones do not trigger the self-healing contract.
public export
data NeedsHealing : HealthZone -> Type where
  ||| Red zone requires healing
  RedNeedsHealing    : NeedsHealing Red
  ||| Purple zone requires healing
  PurpleNeedsHealing : NeedsHealing Purple

||| Proof that Green does NOT need healing.
||| Used to statically verify that the self-healing contract
||| is not spuriously triggered for healthy systems.
public export
greenDoesNotNeedHealing : NeedsHealing Green -> Void
greenDoesNotNeedHealing _ impossible

||| Proof that Yellow does NOT need healing.
public export
yellowDoesNotNeedHealing : NeedsHealing Yellow -> Void
yellowDoesNotNeedHealing _ impossible

||| The self-healing contract: given evidence that the zone needs
||| healing AND auto-heal is enabled, a non-empty list of healing
||| actions MUST be produced.
|||
||| This is the core safety property of the self-healing subsystem.
||| Any implementation of the monitor that claims to support auto-heal
||| must discharge this obligation — it cannot simply log and ignore
||| a critical zone.
|||
||| @param zone     The current health zone
||| @param needsIt  Proof that this zone requires healing
||| @param autoHeal Proof that auto-heal is enabled
||| @param actions  The list of healing actions produced
||| @param nonEmpty Proof that at least one action was produced
public export
record SelfHealingObligation where
  constructor MkSelfHealingObligation
  ||| The zone that triggered healing
  zone     : HealthZone
  ||| Evidence that the zone requires healing
  0 needsIt  : NeedsHealing zone
  ||| Evidence that auto-heal is enabled
  autoHeal : AutoHealEnabled
  ||| The healing actions produced (must be non-empty)
  actions  : List HealingAction
  ||| Proof that the actions list is non-empty
  0 nonEmpty : NonEmpty actions

||| Decide whether a given zone needs healing.
|||
||| Returns a NeedsHealing proof for Red and Purple, or Nothing
||| for Green and Yellow. This enables the caller to conditionally
||| invoke the self-healing contract only when needed.
|||
||| @param zone The zone to check
||| @return     Maybe a proof that this zone needs healing
public export
decideNeedsHealing : (zone : HealthZone) -> Maybe (NeedsHealing zone)
decideNeedsHealing Green  = Nothing
decideNeedsHealing Yellow = Nothing
decideNeedsHealing Red    = Just RedNeedsHealing
decideNeedsHealing Purple = Just PurpleNeedsHealing

--------------------------------------------------------------------------------
-- Watchdog State Machine
--------------------------------------------------------------------------------

||| State of the session-sentinel watchdog process.
|||
||| The watchdog monitors the monitor itself, ensuring liveness.
||| The state machine has three states:
|||   - Healthy:  monitor is running, uptime tracked
|||   - Degraded: monitor is running but experiencing issues
|||   - Failed:   monitor has crashed or become unresponsive
|||
||| The Nat parameter tracks uptime in seconds for Healthy/Degraded states.
public export
data WatchdogState : Type where
  ||| Monitor is running normally with given uptime in seconds
  Healthy  : (uptimeSecs : Nat) -> WatchdogState
  ||| Monitor is running but degraded, with uptime and reason
  Degraded : (uptimeSecs : Nat) -> (reason : String) -> WatchdogState
  ||| Monitor has failed with the given error description
  Failed   : (errorMsg : String) -> WatchdogState

||| Show instance for WatchdogState.
public export
Show WatchdogState where
  show (Healthy u)     = "Healthy(uptime=" ++ show u ++ "s)"
  show (Degraded u r)  = "Degraded(uptime=" ++ show u ++ "s, reason=" ++ r ++ ")"
  show (Failed e)      = "Failed(" ++ e ++ ")"

||| Valid transitions for the watchdog state machine.
|||
||| Key invariant: Failed can ONLY transition to Healthy via
||| ExplicitRecovery. There is no implicit path from Failed to
||| Degraded or from Failed to Healthy without acknowledgment.
|||
||| This ensures that failures are never silently swallowed.
public export
data WatchdogTransition : (from : WatchdogState) -> (to : WatchdogState) -> Type where
  ||| Normal heartbeat: healthy monitor reports continued health
  Heartbeat        : WatchdogTransition (Healthy n) (Healthy (S n))
  ||| Degradation detected: healthy monitor encounters an issue
  WatchdogDegrade  : WatchdogTransition (Healthy n) (Degraded n reason)
  ||| Failure from healthy state (e.g., process crash)
  WatchdogFail     : WatchdogTransition (Healthy n) (Failed msg)
  ||| Degraded monitor continues ticking
  DegradedTick     : WatchdogTransition (Degraded n r) (Degraded (S n) r)
  ||| Degraded monitor recovers to healthy
  DegradedRecover  : WatchdogTransition (Degraded n r) (Healthy n)
  ||| Degraded monitor fails completely
  DegradedFail     : WatchdogTransition (Degraded n r) (Failed msg)
  ||| Explicit recovery: the ONLY way out of Failed state.
  ||| Resets uptime to zero and requires external acknowledgment.
  ExplicitRecovery : WatchdogTransition (Failed msg) (Healthy 0)

||| Proof that Failed state has no implicit transitions to non-Healthy states.
|||
||| The only valid transition from Failed is ExplicitRecovery, which
||| goes to Healthy 0. This function demonstrates that there is no
||| WatchdogTransition from Failed to Degraded.
public export
failedCannotDegrade : WatchdogTransition (Failed msg) (Degraded n r) -> Void
failedCannotDegrade _ impossible

||| Proof that Failed can only go to Healthy with zero uptime.
|||
||| After an explicit recovery, the uptime counter resets. This prevents
||| the system from "remembering" pre-failure uptime, ensuring accurate
||| reliability metrics.
public export
recoveryResetsUptime : WatchdogTransition (Failed msg) (Healthy n)
                    -> n = 0
recoveryResetsUptime ExplicitRecovery = Refl

||| A watchdog trace: sequence of valid transitions from an initial state.
public export
data WatchdogTrace : (start : WatchdogState) -> (end : WatchdogState) -> Type where
  ||| No transitions — watchdog remains in same state
  WatchdogDone : WatchdogTrace s s
  ||| One transition followed by more transitions
  WatchdogStep : WatchdogTransition from mid
              -> WatchdogTrace mid to
              -> WatchdogTrace from to

||| Example: a healthy watchdog that degrades, then recovers.
public export
degradeAndRecover : WatchdogTrace (Healthy 5) (Healthy 5)
degradeAndRecover =
  WatchdogStep WatchdogDegrade
    (WatchdogStep DegradedRecover
      WatchdogDone)

||| Example: failure followed by explicit recovery.
public export
failAndRecover : WatchdogTrace (Healthy 100) (Healthy 0)
failAndRecover =
  WatchdogStep WatchdogFail
    (WatchdogStep ExplicitRecovery
      WatchdogDone)

--------------------------------------------------------------------------------
-- Command-Response Correspondence
--------------------------------------------------------------------------------

||| Type-level mapping from MonitorCommand to expected MonitorResponse type.
|||
||| This ensures that the implementation returns the correct response
||| variant for each command. For example, Scan must produce a
||| HealthReportResponse, never an AckResponse.
public export
ExpectedResponse : MonitorCommand -> Type
ExpectedResponse Scan           = HealthReport
ExpectedResponse Heal           = (List HealingAction, HealthReport)
ExpectedResponse (Diagnose _)   = (AIProvider, ProviderSnapshot, List String)
ExpectedResponse (Configure _)  = String
ExpectedResponse Shutdown       = String

||| Wrap an expected response into the appropriate MonitorResponse variant.
|||
||| @param cmd      The command that was executed
||| @param response The typed response data
||| @return         The wrapped MonitorResponse
public export
wrapResponse : (cmd : MonitorCommand) -> ExpectedResponse cmd -> MonitorResponse
wrapResponse Scan           report         = HealthReportResponse report
wrapResponse Heal           (actions, rpt) = HealingReportResponse actions rpt
wrapResponse (Diagnose _)   (p, s, ds)     = DiagnosticReportResponse p s ds
wrapResponse (Configure _)  msg            = AckResponse msg
wrapResponse Shutdown       msg            = AckResponse msg
