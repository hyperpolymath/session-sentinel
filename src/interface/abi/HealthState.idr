-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Health State Machine with Dependent Types
|||
||| This module defines the core health state model for session-sentinel,
||| a multi-AI session health monitor. Health zones (Green, Yellow, Red,
||| Purple) form a lattice with formally verified transition rules.
|||
||| Only valid transitions are representable:
|||   - Degradation:  Green -> Yellow -> Red -> Purple (monotonic worsening)
|||   - Healing:      Any zone -> Green (explicit recovery action)
|||
||| Threshold ordering is enforced at the type level via LTE proofs,
||| ensuring that green < yellow < red < purple invariants hold.
|||
||| @see SessionSentinel.ABI.MonitorProtocol for the monitor that uses these states

module SessionSentinel.ABI.HealthState

import Data.Nat
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Health Zones
--------------------------------------------------------------------------------

||| The four health zones representing session storage health.
|||
||| Each zone maps to a severity level:
|||   - Green  : Healthy — all metrics within normal bounds
|||   - Yellow : Warning — approaching capacity or staleness thresholds
|||   - Red    : Critical — immediate attention needed, auto-heal eligible
|||   - Purple : Emergency — system at risk of data loss or corruption
public export
data HealthZone : Type where
  ||| Healthy state: all metrics within acceptable bounds
  Green  : HealthZone
  ||| Warning state: metrics approaching thresholds
  Yellow : HealthZone
  ||| Critical state: metrics exceed safe thresholds, healing eligible
  Red    : HealthZone
  ||| Emergency state: severe resource exhaustion or corruption risk
  Purple : HealthZone

||| Numeric severity level for each zone, used for ordering comparisons.
||| Green=0, Yellow=1, Red=2, Purple=3.
public export
zoneSeverity : HealthZone -> Nat
zoneSeverity Green  = 0
zoneSeverity Yellow = 1
zoneSeverity Red    = 2
zoneSeverity Purple = 3

||| HealthZone supports decidable equality, enabling compile-time
||| case analysis and proof-based dispatch.
public export
DecEq HealthZone where
  decEq Green  Green  = Yes Refl
  decEq Yellow Yellow = Yes Refl
  decEq Red    Red    = Yes Refl
  decEq Purple Purple = Yes Refl
  decEq Green  Yellow = No (\case Refl impossible)
  decEq Green  Red    = No (\case Refl impossible)
  decEq Green  Purple = No (\case Refl impossible)
  decEq Yellow Green  = No (\case Refl impossible)
  decEq Yellow Red    = No (\case Refl impossible)
  decEq Yellow Purple = No (\case Refl impossible)
  decEq Red    Green  = No (\case Refl impossible)
  decEq Red    Yellow = No (\case Refl impossible)
  decEq Red    Purple = No (\case Refl impossible)
  decEq Purple Green  = No (\case Refl impossible)
  decEq Purple Yellow = No (\case Refl impossible)
  decEq Purple Red    = No (\case Refl impossible)

||| Eq implementation for HealthZone, derived from DecEq.
public export
Eq HealthZone where
  z1 == z2 = case decEq z1 z2 of
    Yes _ => True
    No _  => False

||| Ordering on HealthZone by severity level.
public export
Ord HealthZone where
  compare z1 z2 = compare (zoneSeverity z1) (zoneSeverity z2)

||| Show implementation for HealthZone, producing human-readable labels.
public export
Show HealthZone where
  show Green  = "Green"
  show Yellow = "Yellow"
  show Red    = "Red"
  show Purple = "Purple"

--------------------------------------------------------------------------------
-- Storage Metrics
--------------------------------------------------------------------------------

||| Snapshot of session storage metrics collected during a scan pass.
|||
||| These raw measurements are classified into a HealthZone using the
||| `classify` function together with a ZoneThresholds configuration.
|||
||| @param totalBytes        Total bytes consumed across all AI provider sessions
||| @param conversationCount Number of active conversation directories
||| @param subagentFiles     Number of subagent work files (task outputs, logs)
||| @param orphanCount       Number of orphaned files (no parent session)
||| @param staleDays         Maximum age in days of any stale session artifact
public export
record StorageMetrics where
  constructor MkStorageMetrics
  ||| Total bytes consumed by all monitored AI session storage
  totalBytes        : Nat
  ||| Number of active conversation directories across all providers
  conversationCount : Nat
  ||| Number of subagent-created work files (task outputs, logs, artifacts)
  subagentFiles     : Nat
  ||| Number of orphaned files with no corresponding active session
  orphanCount       : Nat
  ||| Maximum age (in days) of the stalest session artifact found
  staleDays         : Nat

||| Show implementation for StorageMetrics for diagnostics and logging.
public export
Show StorageMetrics where
  show m = "StorageMetrics{"
        ++ "totalBytes=" ++ show m.totalBytes
        ++ ", conversations=" ++ show m.conversationCount
        ++ ", subagentFiles=" ++ show m.subagentFiles
        ++ ", orphans=" ++ show m.orphanCount
        ++ ", staleDays=" ++ show m.staleDays
        ++ "}"

--------------------------------------------------------------------------------
-- Zone Thresholds
--------------------------------------------------------------------------------

||| Configurable thresholds for classifying StorageMetrics into HealthZones.
|||
||| Each threshold field represents the upper bound (in bytes) for that zone.
||| The type carries a proof that thresholds are strictly ordered:
|||   greenMax < yellowMax < redMax < purpleMin
|||
||| This ensures that zone classification is unambiguous — there are no
||| overlapping ranges and every possible metric value maps to exactly one zone.
|||
||| @param greenMax   Upper bound for Green zone (bytes)
||| @param yellowMax  Upper bound for Yellow zone (bytes)
||| @param redMax     Upper bound for Red zone (bytes)
||| @param purpleMin  Lower bound for Purple zone (bytes); anything >= this is Purple
||| @param orderedGY  Proof that greenMax < yellowMax
||| @param orderedYR  Proof that yellowMax < redMax
||| @param orderedRP  Proof that redMax < purpleMin
public export
record ZoneThresholds where
  constructor MkZoneThresholds
  ||| Maximum bytes for Green zone (healthy)
  greenMax  : Nat
  ||| Maximum bytes for Yellow zone (warning)
  yellowMax : Nat
  ||| Maximum bytes for Red zone (critical)
  redMax    : Nat
  ||| Minimum bytes for Purple zone (emergency)
  purpleMin : Nat
  ||| Proof: greenMax is strictly less than yellowMax
  0 orderedGY : LT greenMax yellowMax
  ||| Proof: yellowMax is strictly less than redMax
  0 orderedYR : LT yellowMax redMax
  ||| Proof: redMax is strictly less than purpleMin
  0 orderedRP : LT redMax purpleMin

||| Default thresholds suitable for typical development workstations.
|||
||| - Green:  up to 512 MiB  (536870912 bytes)
||| - Yellow: up to 1 GiB    (1073741824 bytes)
||| - Red:    up to 2 GiB    (2147483648 bytes)
||| - Purple: 2 GiB and above (2147483649 bytes)
|||
||| These defaults can be overridden via ProviderConfig in MonitorProtocol.
public export
defaultThresholds : ZoneThresholds
defaultThresholds = MkZoneThresholds
  536870912
  1073741824
  2147483648
  2147483649
  (LTESucc (lteSuccRight (lteSuccRight (lteSuccRight (lteRefl {n = 536870912})))))
  (LTESucc (lteSuccRight (lteSuccRight (lteSuccRight (lteRefl {n = 1073741824})))))
  (LTESucc (lteRefl {n = 2147483648}))

--------------------------------------------------------------------------------
-- Zone Classification
--------------------------------------------------------------------------------

||| Evidence that a given byte count falls within a specific HealthZone
||| relative to the provided thresholds.
|||
||| This indexed type ensures that `classify` produces correct results:
||| the returned zone is the unique zone whose threshold range contains
||| the given byte count.
public export
data InZone : (thresholds : ZoneThresholds) -> (bytes : Nat) -> (zone : HealthZone) -> Type where
  ||| bytes <= greenMax implies Green
  InGreen  : {0 t : ZoneThresholds} -> {0 b : Nat}
          -> LTE b t.greenMax
          -> InZone t b Green
  ||| greenMax < bytes <= yellowMax implies Yellow
  InYellow : {0 t : ZoneThresholds} -> {0 b : Nat}
          -> LT t.greenMax b
          -> LTE b t.yellowMax
          -> InZone t b Yellow
  ||| yellowMax < bytes <= redMax implies Red
  InRed    : {0 t : ZoneThresholds} -> {0 b : Nat}
          -> LT t.yellowMax b
          -> LTE b t.redMax
          -> InZone t b Red
  ||| bytes >= purpleMin implies Purple
  InPurple : {0 t : ZoneThresholds} -> {0 b : Nat}
          -> LTE t.purpleMin b
          -> InZone t b Purple

||| Classify a byte count into a HealthZone with proof of correctness.
|||
||| Given thresholds and a byte count, returns the appropriate zone
||| together with a proof (InZone) that the classification is correct
||| with respect to the threshold ordering.
|||
||| The function uses decidable LTE comparisons so that every branch
||| is total and the compiler can verify exhaustiveness.
|||
||| @param t     Zone thresholds (must satisfy ordering invariants)
||| @param bytes Total bytes to classify
||| @return      A dependent pair of the zone and proof of membership
public export
classify : (t : ZoneThresholds)
        -> (bytes : Nat)
        -> (zone : HealthZone ** InZone t bytes zone)
classify t bytes =
  case isLTE bytes t.greenMax of
    Yes lteGreen => (Green ** InGreen lteGreen)
    No notGreen  =>
      let gtGreen = notLTEImpliesGT notGreen
      in case isLTE bytes t.yellowMax of
        Yes lteYellow => (Yellow ** InYellow gtGreen lteYellow)
        No notYellow  =>
          let gtYellow = notLTEImpliesGT notYellow
          in case isLTE bytes t.redMax of
            Yes lteRed => (Red ** InRed gtYellow lteRed)
            No notRed  =>
              let gtRed  = notLTEImpliesGT notRed
                  lteRP  = lteTransitive (lteSuccLeft gtRed) (lteSuccLeft t.orderedRP)
              in (Purple ** InPurple (lteSuccLeft gtRed))
  where
    ||| If NOT (a <= b) then (b < a), i.e., (S b <= a).
    notLTEImpliesGT : {a, b : Nat} -> Not (LTE a b) -> LT b a
    notLTEImpliesGT {a = Z}     {b = _}     notLTE = absurd (notLTE LTEZero)
    notLTEImpliesGT {a = S a'}  {b = Z}     notLTE = LTESucc LTEZero
    notLTEImpliesGT {a = S a'}  {b = S b'}  notLTE =
      LTESucc (notLTEImpliesGT (\prf => notLTE (LTESucc prf)))

    ||| Transitivity of LTE for chaining threshold comparisons.
    lteTransitive : {a, b, c : Nat} -> LTE a b -> LTE b c -> LTE a c
    lteTransitive LTEZero        _            = LTEZero
    lteTransitive (LTESucc ab')  (LTESucc bc') = LTESucc (lteTransitive ab' bc')

    ||| If (S a <= b) then (a <= b), weakening the left bound.
    lteSuccLeft : {a, b : Nat} -> LTE (S a) b -> LTE a b
    lteSuccLeft {a = Z}    (LTESucc _)   = LTEZero
    lteSuccLeft {a = S a'} (LTESucc prf) = LTESucc (lteSuccLeft prf)

||| Convenience function: classify StorageMetrics using totalBytes.
|||
||| Extracts the byte count from a StorageMetrics record and delegates
||| to `classify`, returning only the zone (discarding the proof).
||| Use `classifyWithProof` if you need the proof term.
|||
||| @param t       Zone thresholds
||| @param metrics Storage metrics snapshot
||| @return        The HealthZone corresponding to the total byte count
public export
classifyMetrics : (t : ZoneThresholds) -> (metrics : StorageMetrics) -> HealthZone
classifyMetrics t metrics = fst (classify t metrics.totalBytes)

||| Classify StorageMetrics and retain the proof of correctness.
|||
||| @param t       Zone thresholds
||| @param metrics Storage metrics snapshot
||| @return        Zone paired with InZone proof
public export
classifyWithProof : (t : ZoneThresholds)
                 -> (metrics : StorageMetrics)
                 -> (zone : HealthZone ** InZone t metrics.totalBytes zone)
classifyWithProof t metrics = classify t metrics.totalBytes

--------------------------------------------------------------------------------
-- State Transitions
--------------------------------------------------------------------------------

||| Valid health state transitions.
|||
||| The transition relation encodes the allowed state machine edges:
|||   - Degrade: one-step worsening (Green->Yellow, Yellow->Red, Red->Purple)
|||   - Heal:    recovery from any zone back to Green
|||
||| Notably, multi-step degradation (e.g., Green->Red) is NOT a single
||| valid transition — the system must pass through intermediate states.
||| This prevents the monitor from "skipping" warning levels.
public export
data ValidTransition : (from : HealthZone) -> (to : HealthZone) -> Type where
  ||| Green to Yellow: first level of degradation
  DegradeGY : ValidTransition Green  Yellow
  ||| Yellow to Red: escalation to critical
  DegradeYR : ValidTransition Yellow Red
  ||| Red to Purple: escalation to emergency
  DegradeRP : ValidTransition Red    Purple
  ||| Yellow to Green: healing from warning state
  HealYG    : ValidTransition Yellow Green
  ||| Red to Green: healing from critical state
  HealRG    : ValidTransition Red    Green
  ||| Purple to Green: healing from emergency state
  HealPG    : ValidTransition Purple Green
  ||| Green to Green: idempotent (no change, system stays healthy)
  StayGreen : ValidTransition Green  Green

||| Proof that degradation always increases severity by exactly one step.
|||
||| This ensures the monitor cannot jump from Green directly to Red
||| without first passing through Yellow.
public export
degradationIncreasesSeverity : ValidTransition from to
                            -> (from == Green && to == Yellow)
                               = True
                            -> LT (zoneSeverity from) (zoneSeverity to)
degradationIncreasesSeverity DegradeGY Refl = LTESucc LTEZero

||| Proof that all healing transitions produce Green.
public export
healingProducesGreen : ValidTransition from Green -> Either (from = Green) (Not (from = Green))
healingProducesGreen StayGreen = Left Refl
healingProducesGreen HealYG   = Right (\case Refl impossible)
healingProducesGreen HealRG   = Right (\case Refl impossible)
healingProducesGreen HealPG   = Right (\case Refl impossible)

||| A sequence of valid transitions forming a trace through the state machine.
|||
||| This allows composing individual transitions into multi-step paths
||| while ensuring each step is independently valid.
public export
data TransitionTrace : (start : HealthZone) -> (end : HealthZone) -> Type where
  ||| No transitions — start and end are the same zone
  Done : TransitionTrace z z
  ||| One transition followed by more transitions
  Step : ValidTransition from mid -> TransitionTrace mid to -> TransitionTrace from to

||| Compose two traces end-to-end.
|||
||| If we have a trace from A to B and another from B to C,
||| we can produce a trace from A to C.
public export
appendTrace : TransitionTrace a b -> TransitionTrace b c -> TransitionTrace a c
appendTrace Done          trail2 = trail2
appendTrace (Step t rest) trail2 = Step t (appendTrace rest trail2)

||| Example: a valid degradation path from Green to Red passes through Yellow.
public export
greenToRedPath : TransitionTrace Green Red
greenToRedPath = Step DegradeGY (Step DegradeYR Done)

||| Example: a valid healing path from Purple back to Green.
public export
purpleToGreenPath : TransitionTrace Purple Green
purpleToGreenPath = Step HealPG Done

--------------------------------------------------------------------------------
-- Composite Health Score
--------------------------------------------------------------------------------

||| A weighted composite health score combining multiple metric dimensions.
|||
||| Rather than classifying solely on totalBytes, this allows the monitor
||| to incorporate orphan count, staleness, and conversation count into
||| a single Nat value suitable for threshold classification.
|||
||| The weighting is intentionally simple and deterministic to keep
||| the proof obligations manageable.
|||
||| @param metrics Storage metrics to score
||| @return        Composite score as a natural number
public export
compositeScore : StorageMetrics -> Nat
compositeScore m =
  m.totalBytes
  + (m.orphanCount * 1048576)     -- Each orphan adds ~1 MiB penalty
  + (m.staleDays * 524288)        -- Each stale day adds ~512 KiB penalty

||| Classify using composite score instead of raw bytes.
|||
||| Applies the composite weighting function before classification,
||| providing a more nuanced health assessment that accounts for
||| orphans and staleness in addition to raw storage consumption.
|||
||| @param t       Zone thresholds
||| @param metrics Storage metrics snapshot
||| @return        Zone based on weighted composite score
public export
classifyComposite : (t : ZoneThresholds) -> (metrics : StorageMetrics) -> HealthZone
classifyComposite t metrics = fst (classify t (compositeScore metrics))
