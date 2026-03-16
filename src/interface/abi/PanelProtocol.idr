-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| PanLL Panel Communication Protocol
|||
||| This module defines the message protocol between session-sentinel and
||| PanLL panel instances. PanLL panels display real-time health dashboards,
||| trend visualizations, and provide interactive controls for threshold
||| tuning and manual healing triggers.
|||
||| The protocol enforces a strict correspondence between request and
||| response types at the type level: a RequestSnapshot message can ONLY
||| produce a Snapshot response, never a History or Trend response. This
||| prevents protocol desynchronization between the monitor and panel.
|||
||| Wire format: JSON serialization. Types are annotated with serialization
||| markers to guide code generation for the Zig FFI layer.
|||
||| @see SessionSentinel.ABI.HealthState for zone and metrics types
||| @see SessionSentinel.ABI.MonitorProtocol for health reports and healing

module SessionSentinel.ABI.PanelProtocol

import SessionSentinel.ABI.HealthState
import SessionSentinel.ABI.MonitorProtocol
import Data.Nat
import Data.List
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Timestamped Readings
--------------------------------------------------------------------------------

||| A single timestamped health zone reading.
|||
||| Captured during each scan pass and stored in the trend history buffer.
||| The timestamp is Unix epoch seconds; the zone is the classified result.
|||
||| JSON wire format:
|||   { "timestamp": <nat>, "zone": "<Green|Yellow|Red|Purple>" }
public export
record TimestampedReading where
  constructor MkTimestampedReading
  ||| Unix epoch seconds when this reading was taken
  timestamp : Nat
  ||| Classified health zone at this point in time
  zone      : HealthZone

||| Show instance for TimestampedReading.
public export
Show TimestampedReading where
  show r = "{t=" ++ show r.timestamp ++ ", zone=" ++ show r.zone ++ "}"

||| Eq instance for TimestampedReading based on timestamp and zone.
public export
Eq TimestampedReading where
  r1 == r2 = r1.timestamp == r2.timestamp && r1.zone == r2.zone

--------------------------------------------------------------------------------
-- Trend Data
--------------------------------------------------------------------------------

||| Aggregated trend data over a time window.
|||
||| Provides historical readings, a predicted future zone, and the
||| storage growth rate for capacity planning.
|||
||| JSON wire format:
|||   {
|||     "samples": [ <TimestampedReading>, ... ],
|||     "prediction": { "zone": "<zone>", "hoursAhead": <nat> },
|||     "storageTrendBytesPerDay": <integer>
|||   }
|||
||| @param samples               Chronologically ordered zone readings
||| @param predictedZone         Predicted health zone N hours from now
||| @param predictionHoursAhead  How many hours ahead the prediction covers
||| @param storageTrendBytesPerDay  Net bytes-per-day growth (positive = growing)
public export
record TrendData where
  constructor MkTrendData
  ||| Chronologically ordered zone readings from recent scan history
  samples                : List TimestampedReading
  ||| Predicted health zone based on trend extrapolation
  predictedZone          : HealthZone
  ||| Number of hours ahead the prediction covers
  predictionHoursAhead   : Nat
  ||| Net storage growth rate in bytes per day (positive = growing, zero = stable)
  storageTrendBytesPerDay : Nat

||| Show instance for TrendData.
public export
Show TrendData where
  show td = "TrendData{"
         ++ "samples=" ++ show (length td.samples)
         ++ ", predicted=" ++ show td.predictedZone
         ++ " in " ++ show td.predictionHoursAhead ++ "h"
         ++ ", growth=" ++ show td.storageTrendBytesPerDay ++ "B/day"
         ++ "}"

--------------------------------------------------------------------------------
-- Panel Message Tags (for type-level correspondence)
--------------------------------------------------------------------------------

||| Tag type enumerating the kinds of panel messages.
|||
||| Used as an index for PanelMessage and PanelResponse to enforce
||| that each request variant has exactly one matching response variant.
||| This tag is purely a type-level artifact — it does not appear on
||| the wire.
public export
data PanelTag : Type where
  ||| Tag for snapshot request/response pair
  SnapshotTag   : PanelTag
  ||| Tag for history request/response pair
  HistoryTag    : PanelTag
  ||| Tag for trend request/response pair
  TrendTag      : PanelTag
  ||| Tag for threshold tuning request/ack response pair
  TuneTag       : PanelTag
  ||| Tag for heal trigger request/ack response pair
  HealTrigTag   : PanelTag
  ||| Tag for diagnostic trigger request/ack response pair
  DiagTrigTag   : PanelTag

||| DecEq for PanelTag to support compile-time tag matching.
public export
DecEq PanelTag where
  decEq SnapshotTag SnapshotTag = Yes Refl
  decEq HistoryTag  HistoryTag  = Yes Refl
  decEq TrendTag    TrendTag    = Yes Refl
  decEq TuneTag     TuneTag     = Yes Refl
  decEq HealTrigTag HealTrigTag = Yes Refl
  decEq DiagTrigTag DiagTrigTag = Yes Refl
  decEq SnapshotTag HistoryTag  = No (\case Refl impossible)
  decEq SnapshotTag TrendTag    = No (\case Refl impossible)
  decEq SnapshotTag TuneTag     = No (\case Refl impossible)
  decEq SnapshotTag HealTrigTag = No (\case Refl impossible)
  decEq SnapshotTag DiagTrigTag = No (\case Refl impossible)
  decEq HistoryTag  SnapshotTag = No (\case Refl impossible)
  decEq HistoryTag  TrendTag    = No (\case Refl impossible)
  decEq HistoryTag  TuneTag     = No (\case Refl impossible)
  decEq HistoryTag  HealTrigTag = No (\case Refl impossible)
  decEq HistoryTag  DiagTrigTag = No (\case Refl impossible)
  decEq TrendTag    SnapshotTag = No (\case Refl impossible)
  decEq TrendTag    HistoryTag  = No (\case Refl impossible)
  decEq TrendTag    TuneTag     = No (\case Refl impossible)
  decEq TrendTag    HealTrigTag = No (\case Refl impossible)
  decEq TrendTag    DiagTrigTag = No (\case Refl impossible)
  decEq TuneTag     SnapshotTag = No (\case Refl impossible)
  decEq TuneTag     HistoryTag  = No (\case Refl impossible)
  decEq TuneTag     TrendTag    = No (\case Refl impossible)
  decEq TuneTag     HealTrigTag = No (\case Refl impossible)
  decEq TuneTag     DiagTrigTag = No (\case Refl impossible)
  decEq HealTrigTag SnapshotTag = No (\case Refl impossible)
  decEq HealTrigTag HistoryTag  = No (\case Refl impossible)
  decEq HealTrigTag TrendTag    = No (\case Refl impossible)
  decEq HealTrigTag TuneTag     = No (\case Refl impossible)
  decEq HealTrigTag DiagTrigTag = No (\case Refl impossible)
  decEq DiagTrigTag SnapshotTag = No (\case Refl impossible)
  decEq DiagTrigTag HistoryTag  = No (\case Refl impossible)
  decEq DiagTrigTag TrendTag    = No (\case Refl impossible)
  decEq DiagTrigTag TuneTag     = No (\case Refl impossible)
  decEq DiagTrigTag HealTrigTag = No (\case Refl impossible)

--------------------------------------------------------------------------------
-- Panel Messages (Requests)
--------------------------------------------------------------------------------

||| Messages sent FROM a PanLL panel TO the session-sentinel monitor.
|||
||| Indexed by PanelTag so that the type system tracks which kind of
||| response is expected. The panel sends one of these, and the monitor
||| MUST reply with the corresponding PanelResponse indexed by the
||| same tag.
|||
||| JSON wire format:
|||   { "type": "<tag>", ...fields... }
public export
data PanelMessage : PanelTag -> Type where
  ||| Request current health snapshot.
  ||| The monitor replies with the latest HealthReport.
  |||
  ||| JSON: { "type": "snapshot" }
  RequestSnapshot  : PanelMessage SnapshotTag

  ||| Request historical health reports.
  ||| The Nat parameter specifies how many recent reports to return.
  |||
  ||| JSON: { "type": "history", "count": <nat> }
  RequestHistory   : (count : Nat) -> PanelMessage HistoryTag

  ||| Request trend analysis data.
  ||| The monitor replies with samples, prediction, and growth rate.
  |||
  ||| JSON: { "type": "trend" }
  RequestTrend     : PanelMessage TrendTag

  ||| Tune a zone threshold to a new value.
  ||| The panel user adjusts a threshold slider; the monitor validates
  ||| and applies the change (or rejects if ordering would be violated).
  |||
  ||| JSON: { "type": "tune", "zone": "<zone>", "newValue": <nat> }
  TuneThreshold    : (zone : HealthZone) -> (newValue : Nat) -> PanelMessage TuneTag

  ||| Trigger a manual healing pass.
  ||| Equivalent to sending a Heal command via MonitorProtocol.
  |||
  ||| JSON: { "type": "heal" }
  TriggerHeal      : PanelMessage HealTrigTag

  ||| Trigger a full diagnostic scan.
  ||| Results are returned as a detailed diagnostic string list.
  |||
  ||| JSON: { "type": "diagnostic" }
  TriggerDiagnostic : PanelMessage DiagTrigTag

--------------------------------------------------------------------------------
-- Panel Responses
--------------------------------------------------------------------------------

||| Responses sent FROM the session-sentinel monitor TO a PanLL panel.
|||
||| Indexed by the same PanelTag as the originating PanelMessage,
||| enforcing that the response type matches the request type at
||| compile time.
|||
||| JSON wire format:
|||   { "type": "<tag>", "status": "ok"|"error", ...fields... }
public export
data PanelResponse : PanelTag -> Type where
  ||| Current health snapshot in response to RequestSnapshot.
  |||
  ||| JSON: { "type": "snapshot", "status": "ok", "report": <HealthReport> }
  Snapshot     : HealthReport -> PanelResponse SnapshotTag

  ||| Historical reports in response to RequestHistory.
  ||| The list length is at most the requested count.
  |||
  ||| JSON: { "type": "history", "status": "ok", "reports": [<HealthReport>, ...] }
  History      : (reports : List HealthReport) -> PanelResponse HistoryTag

  ||| Trend analysis data in response to RequestTrend.
  |||
  ||| JSON: { "type": "trend", "status": "ok", "data": <TrendData> }
  Trend        : TrendData -> PanelResponse TrendTag

  ||| Acknowledgment that a threshold was successfully tuned.
  ||| The message describes what changed.
  |||
  ||| JSON: { "type": "tune", "status": "ok", "message": "<string>" }
  TuneAck      : (message : String) -> PanelResponse TuneTag

  ||| Acknowledgment that healing was triggered, with action summary.
  |||
  ||| JSON: { "type": "heal", "status": "ok", "message": "<string>" }
  HealAck      : (message : String) -> PanelResponse HealTrigTag

  ||| Diagnostic results in response to TriggerDiagnostic.
  |||
  ||| JSON: { "type": "diagnostic", "status": "ok", "message": "<string>" }
  DiagnosticAck : (message : String) -> PanelResponse DiagTrigTag

  ||| Error response for any tag. Panels must handle errors for every
  ||| request type they send.
  |||
  ||| JSON: { "type": "<tag>", "status": "error", "error": "<string>" }
  PanelError   : {tag : PanelTag} -> (message : String) -> PanelResponse tag

--------------------------------------------------------------------------------
-- Protocol Correspondence Proofs
--------------------------------------------------------------------------------

||| Proof that a Snapshot response can only come from a SnapshotTag.
|||
||| This is structurally guaranteed by the PanelResponse GADT, but
||| this lemma makes it explicit for downstream consumers that need
||| to reason about protocol correctness.
public export
snapshotIsSnapshot : PanelResponse SnapshotTag -> Either HealthReport String
snapshotIsSnapshot (Snapshot r)  = Left r
snapshotIsSnapshot (PanelError e) = Right e

||| Proof that a History response can only come from a HistoryTag.
public export
historyIsHistory : PanelResponse HistoryTag -> Either (List HealthReport) String
historyIsHistory (History rs)   = Left rs
historyIsHistory (PanelError e) = Right e

||| Proof that a Trend response can only come from a TrendTag.
public export
trendIsTrend : PanelResponse TrendTag -> Either TrendData String
trendIsTrend (Trend td)     = Left td
trendIsTrend (PanelError e) = Right e

||| Type-safe protocol handler signature.
|||
||| Any panel protocol handler must accept a PanelMessage of some tag
||| and produce a PanelResponse of the SAME tag. This type alias
||| makes it easy to define handlers that the compiler verifies.
|||
||| @param tag The panel tag indexing both request and response
public export
PanelHandler : PanelTag -> Type
PanelHandler tag = PanelMessage tag -> PanelResponse tag

--------------------------------------------------------------------------------
-- Existential Message Wrapper (for wire deserialization)
--------------------------------------------------------------------------------

||| An existential wrapper around PanelMessage for use when the tag
||| is not known at compile time (e.g., after JSON deserialization).
|||
||| The tag is packed alongside the message so that dispatching code
||| can pattern-match on the tag and recover the typed message.
|||
||| JSON deserialization produces this type; the dispatcher then
||| unwraps it and routes to the appropriate PanelHandler.
public export
data SomePanelMessage : Type where
  ||| A panel message with its tag existentially quantified
  MkSomePanelMessage : {tag : PanelTag} -> PanelMessage tag -> SomePanelMessage

||| An existential wrapper around PanelResponse for wire serialization.
|||
||| Used when responses need to be placed in a heterogeneous collection
||| (e.g., a batch response list) where the tag varies per element.
public export
data SomePanelResponse : Type where
  ||| A panel response with its tag existentially quantified
  MkSomePanelResponse : {tag : PanelTag} -> PanelResponse tag -> SomePanelResponse

--------------------------------------------------------------------------------
-- Dispatch Function
--------------------------------------------------------------------------------

||| Dispatch a deserialized message to the appropriate typed handler.
|||
||| Takes a record of handlers (one per tag) and an existential message,
||| pattern-matches on the tag, and invokes the correct handler.
||| Returns an existential response suitable for serialization.
|||
||| @param handlers Record of per-tag handlers
||| @param msg      Existentially wrapped incoming message
||| @return         Existentially wrapped response
public export
record PanelHandlers where
  constructor MkPanelHandlers
  ||| Handler for snapshot requests
  handleSnapshot   : PanelHandler SnapshotTag
  ||| Handler for history requests
  handleHistory    : PanelHandler HistoryTag
  ||| Handler for trend requests
  handleTrend      : PanelHandler TrendTag
  ||| Handler for threshold tuning requests
  handleTune       : PanelHandler TuneTag
  ||| Handler for heal trigger requests
  handleHeal       : PanelHandler HealTrigTag
  ||| Handler for diagnostic trigger requests
  handleDiagnostic : PanelHandler DiagTrigTag

||| Dispatch an existentially-typed panel message to the correct handler.
|||
||| The tag determines which handler is invoked. The returned response
||| is wrapped existentially for uniform wire serialization.
|||
||| @param handlers The complete set of tag-indexed handlers
||| @param msg      An incoming message with unknown (existential) tag
||| @return         The corresponding response, existentially wrapped
public export
dispatch : PanelHandlers -> SomePanelMessage -> SomePanelResponse
dispatch hs (MkSomePanelMessage {tag = SnapshotTag} msg) =
  MkSomePanelResponse (hs.handleSnapshot msg)
dispatch hs (MkSomePanelMessage {tag = HistoryTag} msg) =
  MkSomePanelResponse (hs.handleHistory msg)
dispatch hs (MkSomePanelMessage {tag = TrendTag} msg) =
  MkSomePanelResponse (hs.handleTrend msg)
dispatch hs (MkSomePanelMessage {tag = TuneTag} msg) =
  MkSomePanelResponse (hs.handleTune msg)
dispatch hs (MkSomePanelMessage {tag = HealTrigTag} msg) =
  MkSomePanelResponse (hs.handleHeal msg)
dispatch hs (MkSomePanelMessage {tag = DiagTrigTag} msg) =
  MkSomePanelResponse (hs.handleDiagnostic msg)

--------------------------------------------------------------------------------
-- Serialization Markers
--------------------------------------------------------------------------------

||| Marker interface for types that can be serialized to JSON.
|||
||| This does not provide an implementation — it serves as a
||| compile-time marker that code generators (Zig FFI layer) use
||| to identify types requiring JSON serialization support.
|||
||| Implementations are generated in the FFI layer, not in Idris2.
public export
interface JsonSerializable a where
  ||| Unique type tag string used in the JSON "type" field.
  ||| Must be stable across versions for wire compatibility.
  jsonTypeTag : String

||| TimestampedReading is JSON-serializable.
public export
JsonSerializable TimestampedReading where
  jsonTypeTag = "timestamped_reading"

||| TrendData is JSON-serializable.
public export
JsonSerializable TrendData where
  jsonTypeTag = "trend_data"

||| HealthReport is JSON-serializable (imported from MonitorProtocol).
public export
JsonSerializable HealthReport where
  jsonTypeTag = "health_report"

||| StorageMetrics is JSON-serializable (imported from HealthState).
public export
JsonSerializable StorageMetrics where
  jsonTypeTag = "storage_metrics"

||| HealthZone is JSON-serializable (imported from HealthState).
public export
JsonSerializable HealthZone where
  jsonTypeTag = "health_zone"

--------------------------------------------------------------------------------
-- Panel Registration
--------------------------------------------------------------------------------

||| Unique identifier for a connected PanLL panel instance.
|||
||| Each panel gets a unique ID upon registration so that the monitor
||| can route responses and manage panel lifecycle (disconnect, reconnect).
public export
record PanelId where
  constructor MkPanelId
  ||| Unique numeric identifier assigned by the monitor
  idValue : Nat
  ||| Human-readable panel name (e.g., "system-tray-dashboard")
  name    : String

||| Eq instance for PanelId based on numeric identifier.
public export
Eq PanelId where
  p1 == p2 = p1.idValue == p2.idValue

||| Show instance for PanelId.
public export
Show PanelId where
  show p = "Panel(" ++ show p.idValue ++ ":" ++ p.name ++ ")"

||| Panel registration state.
|||
||| Tracks whether a panel is connected, disconnected, or in the
||| process of reconnecting. The monitor uses this to manage
||| message routing and cleanup.
public export
data PanelState : Type where
  ||| Panel is connected and receiving messages
  Connected    : (since : Nat) -> PanelState
  ||| Panel has disconnected (timestamp of last message)
  Disconnected : (lastSeen : Nat) -> PanelState
  ||| Panel is attempting to reconnect
  Reconnecting : (attempts : Nat) -> PanelState

||| Show instance for PanelState.
public export
Show PanelState where
  show (Connected s)    = "Connected(since=" ++ show s ++ ")"
  show (Disconnected l) = "Disconnected(lastSeen=" ++ show l ++ ")"
  show (Reconnecting a) = "Reconnecting(attempts=" ++ show a ++ ")"

||| A registered panel with its identifier and current state.
public export
record RegisteredPanel where
  constructor MkRegisteredPanel
  ||| Unique panel identifier
  panelId : PanelId
  ||| Current connection state
  state   : PanelState

||| Show instance for RegisteredPanel.
public export
Show RegisteredPanel where
  show rp = "RegisteredPanel{" ++ show rp.panelId ++ ", " ++ show rp.state ++ "}"
