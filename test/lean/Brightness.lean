import Std

/-!
Executable specification, not a verified translation of Bash or QML.
Inputs represent successful capability discovery, durable reservations/checkpoints, subprocess
exit status, identity-anchored readback and record removal. Their truthfulness and
atomicity are integration assumptions, not axioms added to Lean. See
docs/BRIGHTNESS_PROOFS.md for the boundary and finite JS conformance checks.
-/
namespace OmachordBrightness

structure Target where
  name : String
  metadataDigest : String
  deriving DecidableEq, Repr

structure Capability where
  target : Target
  before : Nat
  externalDDC : Bool
  deriving DecidableEq, Repr

-- Boundary abstraction: every present availability field must be a JSON bool.
-- The adapter must supply ALL such fields, not just the first matching one.
inductive AvailabilityField where
  | absent | flag (value : Bool) | invalid
  deriving DecidableEq, Repr

def availabilityWellFormed : AvailabilityField → Bool
  | .invalid => false
  | _ => true

def checkedName (name : String) (fields : List AvailabilityField) : Option String :=
  if name = "" ∨ fields.all availabilityWellFormed = false then none else some name

-- none as value means read; some value means write. Neither has a fallback.
def namedBrightnessRequest (name : Option String) (value : Option Nat) : Option (String × Option Nat) :=
  match name with
  | none => none
  | some name => if name = "" then none else some (name, value)

theorem invalid_availability_field_rejected (name : String) (earlier later : List AvailabilityField) :
    checkedName name (earlier ++ .invalid :: later) = none := by
  simp [checkedName, availabilityWellFormed]

theorem absent_or_empty_name_never_falls_back (value : Option Nat) :
    namedBrightnessRequest none value = none ∧ namedBrightnessRequest (some "") value = none := by
  simp [namedBrightnessRequest]

theorem named_request_uses_checked_name (name : String) (value : Option Nat) (h : name ≠ "") :
    namedBrightnessRequest (some name) value = some (name, value) := by
  simp [namedBrightnessRequest, h]

-- Projection of the v3 envelope and ONE populated brightness setter entry.
-- This is not the initial reservation, whose setters are still empty.
structure Snapshot where
  version : Nat
  target : Target
  before : Nat
  applied : Nat
  confirmed : Bool
  deriving DecidableEq, Repr

structure Reservation where
  version : Nat
  claims : List Nat
  setters : List Snapshot
  brightnessTarget : Option Target
  deriving DecidableEq, Repr

-- Claims are abstract resource identifiers, not populated setter entries.
def reservation (claims : List Nat) (target : Option Target) : Reservation :=
  ⟨if target.isSome then 3 else 2, claims, [], target⟩

theorem reservation_contract (claims : List Nat) (target : Target) :
    (reservation claims (some target)).version = 3 ∧
    (reservation claims (some target)).claims = claims ∧
    (reservation claims (some target)).setters = [] ∧
    (reservation claims (some target)).brightnessTarget = some target := by simp [reservation]

-- Requests have already passed percentage/range validation at this boundary.
def normalize (externalDDC : Bool) (requested : Nat) : Nat :=
  if externalDDC && requested == 0 then 1 else requested

def checkpoint (cap : Capability) (requested : Nat) : Snapshot :=
  ⟨3, cap.target, cap.before, normalize cap.externalDDC requested, false⟩

theorem external_zero_normalized : normalize true 0 = 1 := rfl
theorem internal_zero_preserved : normalize false 0 = 0 := rfl

theorem checkpoint_contract (cap : Capability) (requested : Nat) :
    (checkpoint cap requested).version = 3 ∧
    (checkpoint cap requested).target = cap.target ∧
    (checkpoint cap requested).before = cap.before ∧
    (checkpoint cap requested).applied = normalize cap.externalDDC requested ∧
    (checkpoint cap requested).confirmed = false := by
  simp [checkpoint]

inductive Event where
  | preflight
  | reservationWritten (reservation : Reservation)
  | checkpointWritten (snapshot : Snapshot)
  | routineEffect (action : Nat)
  | brightnessWrite (target : Target) (value : Nat)
  | receiptWritten (snapshot : Snapshot)
  deriving DecidableEq, Repr

structure Start where
  blocked : Bool
  events : List Event
  deriving DecidableEq, Repr

def requiresBrightness (startBrightness endBrightness : Bool) : Bool :=
  startBrightness || endBrightness

-- Preflight gates all actions, including earlier non-brightness actions and
-- requirements declared only in onEnd. target is the checked preflight result.
-- Only stateful runs also persist a reservation before admitting actions.
-- Populated brightness entries are deferred to brightnessStep below.
def start (startBrightness endBrightness stateful reservationWritten : Bool)
    (target : Option Target) (claims actions : List Nat) : Start :=
  let declared := requiresBrightness startBrightness endBrightness
  let initialEvents := if declared then [Event.preflight] else []
  if declared && target.isNone then ⟨true, initialEvents⟩
  else if stateful then
    if reservationWritten then
      ⟨false, initialEvents ++ [.reservationWritten (reservation claims (if declared then target else none))]
        ++ actions.map Event.routineEffect⟩
    else ⟨false, initialEvents⟩
  else ⟨false, initialEvents ++ actions.map Event.routineEffect⟩

theorem failed_preflight_blocks_all_effects (onStart onEnd stateful written : Bool)
    (claims actions : List Nat) (h : requiresBrightness onStart onEnd = true) :
    start onStart onEnd stateful written none claims actions = ⟨true, [.preflight]⟩ := by
  simp [start, h]

theorem failed_reservation_prevents_all_effects (target : Target) (claims actions : List Nat) :
    (start true false true false (some target) claims actions).events = [.preflight] := rfl

theorem preflight_and_reservation_precede_all_effects (target : Target) (claims actions : List Nat) :
    (start true false true true (some target) claims actions).events =
      [.preflight, .reservationWritten (reservation claims (some target))]
        ++ actions.map Event.routineEffect := rfl

theorem stateless_preflight_without_reservation (target : Target) (written : Bool) (claims actions : List Nat) :
    (start true false false written (some target) claims actions).events =
      [.preflight] ++ actions.map Event.routineEffect := rfl

theorem end_only_brightness_reserves_target (target : Target) (claims actions : List Nat) :
    (start false true true true (some target) claims actions).events =
      [.preflight, .reservationWritten (reservation claims (some target))]
        ++ actions.map Event.routineEffect := rfl

-- A zero exit alone is insufficient: both identity and exact value must match.
def confirmedWrite (target : Target) (value : Nat) (exitSuccess : Bool)
    (readback : Option (Target × Nat)) : Bool :=
  exitSuccess && decide (readback = some (target, value))

def receiptAfterSet (s : Snapshot) (exitSuccess : Bool)
    (readback : Option (Target × Nat)) (persistSuccess : Bool) : Snapshot :=
  { s with confirmed := confirmedWrite s.target s.applied exitSuccess readback && persistSuccess }

theorem receipt_requires_exit_readback_and_persistence (s : Snapshot)
    (exitSuccess persistSuccess : Bool) (readback : Option (Target × Nat)) :
    (receiptAfterSet s exitSuccess readback persistSuccess).confirmed = true ↔
      exitSuccess = true ∧ readback = some (s.target, s.applied) ∧ persistSuccess = true := by
  simp [receiptAfterSet, confirmedWrite, and_assoc]

theorem receipt_preserves_pin_and_values (s : Snapshot) (exitSuccess persistSuccess : Bool)
    (readback : Option (Target × Nat)) :
    (receiptAfterSet s exitSuccess readback persistSuccess).target = s.target ∧
    (receiptAfterSet s exitSuccess readback persistSuccess).before = s.before ∧
    (receiptAfterSet s exitSuccess readback persistSuccess).applied = s.applied ∧
    (receiptAfterSet s exitSuccess readback persistSuccess).version = s.version := by
  simp [receiptAfterSet]

-- Local expansion when a journaled brightness action is reached. Earlier
-- routine effects may already have happened. Stateless, nonrestoring writes
-- are not modeled by this journaled step.
def brightnessStep (cap : Capability) (requested : Nat) (checkpointWritten exitSuccess : Bool)
    (readback : Option (Target × Nat)) (persistSuccess : Bool) : List Event :=
  let s := checkpoint cap requested
  let receipt := receiptAfterSet s exitSuccess readback persistSuccess
  if checkpointWritten then
    [.checkpointWritten s, .brightnessWrite s.target s.applied] ++
      (if receipt.confirmed then [.receiptWritten receipt] else [])
  else []

theorem failed_brightness_checkpoint_preserves_earlier_effects (earlier : List Event)
    (cap : Capability) (requested : Nat) (exitSuccess persistSuccess : Bool)
    (readback : Option (Target × Nat)) :
    earlier ++ brightnessStep cap requested false exitSuccess readback persistSuccess = earlier := by
  simp [brightnessStep]

theorem brightness_checkpoint_precedes_its_write (cap : Capability) (requested : Nat)
    (exitSuccess persistSuccess : Bool) (readback : Option (Target × Nat)) :
    (brightnessStep cap requested true exitSuccess readback persistSuccess).take 2 =
      [.checkpointWritten (checkpoint cap requested),
       .brightnessWrite cap.target (normalize cap.externalDDC requested)] := rfl

theorem confirmed_receipt_follows_its_write (cap : Capability) (requested : Nat)
    (exitSuccess persistSuccess : Bool) (readback : Option (Target × Nat))
    (h : (receiptAfterSet (checkpoint cap requested) exitSuccess readback persistSuccess).confirmed = true) :
    brightnessStep cap requested true exitSuccess readback persistSuccess =
      [.checkpointWritten (checkpoint cap requested),
       .brightnessWrite cap.target (normalize cap.externalDDC requested),
       .receiptWritten (receiptAfterSet (checkpoint cap requested) exitSuccess readback persistSuccess)] := by
  simp [brightnessStep, h]
  exact ⟨rfl, rfl⟩

inductive RestoreState where
  | fresh | pending | done | skipped
  deriving DecidableEq, Repr

inductive RestoreDecision where
  | hold | complete | markDone | skipTarget | writeBefore
  deriving DecidableEq, Repr

-- Read-only decision. In particular, pending overrides activation confirmation.
def restoreDecision (s : Snapshot) (state : RestoreState)
    (observation : Option (Target × Nat)) : RestoreDecision :=
  if state = .done ∨ state = .skipped then .complete
  else match observation with
  | none => .hold
  | some (target, current) =>
    if target ≠ s.target then .hold
    else if state = .pending then
      if current = s.before then .markDone
      else if current = s.applied then .writeBefore else .hold
    else if current = s.applied then .writeBefore
    else if s.confirmed then .skipTarget
    else if current = s.before then .markDone else .hold

def restoreRequest (s : Snapshot) : RestoreDecision → Option (Target × Nat)
  | .writeBefore => some (s.target, s.before)
  | _ => none

theorem unavailable_live_target_holds (s : Snapshot) (state : RestoreState)
    (hd : state ≠ .done) (hs : state ≠ .skipped) :
    restoreDecision s state none = .hold := by simp [restoreDecision, hd, hs]

theorem mismatched_live_target_holds (s : Snapshot) (state : RestoreState) (target : Target)
    (current : Nat) (hd : state ≠ .done) (hs : state ≠ .skipped) (ht : target ≠ s.target) :
    restoreDecision s state (some (target, current)) = .hold := by simp [restoreDecision, hd, hs, ht]

theorem pending_before_marks_done_without_write (s : Snapshot) :
    restoreDecision s .pending (some (s.target, s.before)) = .markDone := by simp [restoreDecision]

theorem pending_applied_retries (s : Snapshot) (h : s.applied ≠ s.before) :
    restoreDecision s .pending (some (s.target, s.applied)) = .writeBefore := by simp [restoreDecision, h]

theorem pending_ambiguous_holds_even_if_activation_confirmed (s : Snapshot) (current : Nat)
    (hb : current ≠ s.before) (ha : current ≠ s.applied) :
    restoreDecision s .pending (some (s.target, current)) = .hold := by simp [restoreDecision, hb, ha]

theorem confirmed_manual_change_skips_target (s : Snapshot) (current : Nat)
    (hc : s.confirmed = true) (ha : current ≠ s.applied) :
    restoreDecision s .fresh (some (s.target, current)) = .skipTarget := by simp [restoreDecision, hc, ha]

theorem unconfirmed_ambiguous_value_holds (s : Snapshot) (current : Nat)
    (hc : s.confirmed = false) (ha : current ≠ s.applied) (hb : current ≠ s.before) :
    restoreDecision s .fresh (some (s.target, current)) = .hold := by simp [restoreDecision, hc, ha, hb]

theorem unconfirmed_before_marks_done (s : Snapshot) (hc : s.confirmed = false) (h : s.before ≠ s.applied) :
    restoreDecision s .fresh (some (s.target, s.before)) = .markDone := by simp [restoreDecision, hc, h]

theorem fresh_applied_requests_before (s : Snapshot) :
    restoreRequest s (restoreDecision s .fresh (some (s.target, s.applied))) =
      some (s.target, s.before) := by simp [restoreDecision, restoreRequest]

theorem any_write_is_pinned (s : Snapshot) (decision : RestoreDecision) (target : Target) (value : Nat)
    (h : restoreRequest s decision = some (target, value)) :
    target = s.target ∧ value = s.before := by
  cases decision <;> simp_all [restoreRequest]

-- Binding a legacy record identifies a target; it cannot attest to an old write.
def bindLegacy (target : Target) (before applied : Nat) : Snapshot :=
  ⟨3, target, before, applied, false⟩

theorem legacy_binding_never_confirms (target : Target) (before applied : Nat) :
    (bindLegacy target before applied).target = target ∧
    (bindLegacy target before applied).confirmed = false := by simp [bindLegacy]

inductive RestoreEffect where
  | checkpoint (state : RestoreState)
  | skipTargetReceipt
  | write (target : Target) (value : Nat)
  | remove
  deriving DecidableEq, Repr

-- Successful journal writes are events. A failed setter still issued its write
-- and leaves pending. Removal is deliberately NOT a per-entry operation.
def restoreEffects (s : Snapshot) (decision : RestoreDecision) (pendingWritten exitSuccess : Bool)
    (readback : Option (Target × Nat)) (finishWritten : Bool) : List RestoreEffect :=
  match decision with
  | .writeBefore =>
    if pendingWritten then
      [.checkpoint .pending, .write s.target s.before] ++
        (if confirmedWrite s.target s.before exitSuccess readback && finishWritten then [.checkpoint .done] else [])
    else []
  | .markDone => if finishWritten then [.checkpoint .done] else []
  | .skipTarget => if finishWritten then [.skipTargetReceipt] else []
  | _ => []

theorem held_read_has_no_record_or_device_effect (s : Snapshot) (pendingWritten exitSuccess finishWritten : Bool)
    (readback : Option (Target × Nat)) :
    restoreEffects s .hold pendingWritten exitSuccess readback finishWritten = [] := rfl

theorem failed_pending_checkpoint_prevents_restore_write (s : Snapshot) (exitSuccess finishWritten : Bool)
    (readback : Option (Target × Nat)) :
    restoreEffects s .writeBefore false exitSuccess readback finishWritten = [] := rfl

theorem pending_receipt_precedes_restore_write (s : Snapshot) (exitSuccess finishWritten : Bool)
    (readback : Option (Target × Nat)) :
    (restoreEffects s .writeBefore true exitSuccess readback finishWritten).take 2 =
      [.checkpoint .pending, .write s.target s.before] := rfl

theorem failed_restore_confirmation_leaves_pending (s : Snapshot) (exitSuccess finishWritten : Bool)
    (readback : Option (Target × Nat)) (h : confirmedWrite s.target s.before exitSuccess readback = false) :
    restoreEffects s .writeBefore true exitSuccess readback finishWritten =
      [.checkpoint .pending, .write s.target s.before] := by simp [restoreEffects, h]

theorem confirmed_restore_persists_done_after_write (s : Snapshot) :
    restoreEffects s .writeBefore true true (some (s.target, s.before)) true =
      [.checkpoint .pending, .write s.target s.before, .checkpoint .done] := by simp [restoreEffects, confirmedWrite]

theorem mark_done_has_no_device_write (s : Snapshot) (pendingWritten exitSuccess : Bool)
    (readback : Option (Target × Nat)) :
    restoreEffects s .markDone pendingWritten exitSuccess readback true = [.checkpoint .done] := rfl

structure RestoreEntry where
  snapshot : Snapshot
  state : RestoreState
  deriving DecidableEq, Repr

def skipEntry (target : Target) (entry : RestoreEntry) : RestoreEntry :=
  if entry.snapshot.target = target ∧ entry.state ≠ .done then { entry with state := .skipped } else entry

-- One atomic snapshot replacement, not one commit per entry. A failed commit
-- changes no entries. casRun below additionally guards the expected fingerprint.
def commitSkipTarget (success : Bool) (target : Target) (entries : List RestoreEntry) : List RestoreEntry :=
  if success then entries.map (skipEntry target) else entries

theorem failed_skip_commit_preserves_all_entries (target : Target) (entries : List RestoreEntry) :
    commitSkipTarget false target entries = entries := rfl

theorem skipped_same_target_entry_never_resumes (target : Target) (entry : RestoreEntry)
    (observation : Option (Target × Nat)) (h : entry.snapshot.target = target) :
    restoreDecision (skipEntry target entry).snapshot (skipEntry target entry).state observation = .complete := by
  by_cases hd : entry.state = .done <;> simp [skipEntry, h, hd, restoreDecision]

theorem committed_skip_completes_all_same_target_entries (target : Target) (entries : List RestoreEntry)
    (entry : RestoreEntry) (observation : Option (Target × Nat))
    (he : entry ∈ commitSkipTarget true target entries) (ht : entry.snapshot.target = target) :
    restoreDecision entry.snapshot entry.state observation = .complete := by
  change entry ∈ entries.map (skipEntry target) at he
  obtain ⟨original, _, rfl⟩ := List.mem_map.mp he
  have hp : (skipEntry target original).snapshot = original.snapshot := by
    unfold skipEntry
    split <;> rfl
  exact skipped_same_target_entry_never_resumes target original observation (hp ▸ ht)

theorem skip_commit_preserves_other_targets (target : Target) (entry : RestoreEntry)
    (h : entry.snapshot.target ≠ target) : skipEntry target entry = entry := by simp [skipEntry, h]

structure ChainStep where
  effects : List RestoreEffect
  continueOlder : Bool

def restoreChainStep (s : Snapshot) (decision : RestoreDecision) (pendingWritten exitSuccess : Bool)
    (readback : Option (Target × Nat)) (finishWritten : Bool) : ChainStep :=
  ⟨restoreEffects s decision pendingWritten exitSuccess readback finishWritten,
    match decision with
    | .complete => true
    | .markDone => finishWritten
    | .writeBefore => pendingWritten && confirmedWrite s.target s.before exitSuccess readback && finishWritten
    | _ => false⟩

-- One target's entries in newest-first order. Other targets are independent;
-- this is not a model of the production loop's parsing or target grouping.
def runTargetChain : List ChainStep → List RestoreEffect
  | [] => []
  | step :: older => step.effects ++ if step.continueOlder then runTargetChain older else []

theorem stopped_target_pass_never_runs_older (effects : List RestoreEffect) (older : List ChainStep) :
    runTargetChain (⟨effects, false⟩ :: older) = effects := by simp [runTargetChain]

theorem uncertainty_stops_older_target_entries (s : Snapshot) (pendingWritten exitSuccess finishWritten : Bool)
    (readback : Option (Target × Nat)) (older : List ChainStep) :
    runTargetChain (restoreChainStep s .hold pendingWritten exitSuccess readback finishWritten :: older) = [] := rfl

theorem manual_override_stops_older_target_entries (s : Snapshot) (pendingWritten exitSuccess finishWritten : Bool)
    (readback : Option (Target × Nat)) (older : List ChainStep) :
    runTargetChain (restoreChainStep s .skipTarget pendingWritten exitSuccess readback finishWritten :: older) =
      restoreEffects s .skipTarget pendingWritten exitSuccess readback finishWritten := by
  simp [runTargetChain, restoreChainStep]

theorem failed_write_stops_older_target_entries (s : Snapshot) (pendingWritten finishWritten : Bool)
    (readback : Option (Target × Nat)) (older : List ChainStep) :
    runTargetChain (restoreChainStep s .writeBefore pendingWritten false readback finishWritten :: older) =
      restoreEffects s .writeBefore pendingWritten false readback finishWritten := by
  simp [runTargetChain, restoreChainStep, confirmedWrite]

theorem failed_finish_receipt_stops_older_target_entries (s : Snapshot) (decision : RestoreDecision)
    (pendingWritten exitSuccess : Bool) (readback : Option (Target × Nat)) (older : List ChainStep)
    (h : decision ≠ .complete) :
    runTargetChain (restoreChainStep s decision pendingWritten exitSuccess readback false :: older) =
      restoreEffects s decision pendingWritten exitSuccess readback false := by
  cases decision <;> simp_all [runTargetChain, restoreChainStep]

structure GuardedRestoreEffect where
  observedFingerprint : String
  nextFingerprint : String
  effect : RestoreEffect

-- Expected fingerprint comes from the original read (or pending retry read).
-- After a successful receipt checkpoint it advances to that checkpoint's token;
-- a device write cannot rebase it. Any mismatch stops the entire remaining plan.
-- Effects in the plan assume their persistence succeeds; failed persistence
-- produces no successful checkpoint event and no continuation in restoreEffects.
def casRun (expected : String) : List GuardedRestoreEffect → List RestoreEffect
  | [] => []
  | step :: rest =>
    if step.observedFingerprint = expected then
      step.effect :: match step.effect with
      | .checkpoint _ | .skipTargetReceipt => casRun step.nextFingerprint rest
      | .write _ _ => casRun expected rest
      | .remove => []
    else []

theorem cas_conflict_prevents_all_further_effects (expected : String) (step : GuardedRestoreEffect)
    (rest : List GuardedRestoreEffect) (h : step.observedFingerprint ≠ expected) :
    casRun expected (step :: rest) = [] := by simp [casRun, h]

theorem cas_checkpoint_carries_new_fingerprint (expected next : String) (state : RestoreState)
    (rest : List GuardedRestoreEffect) :
    casRun expected (⟨expected, next, .checkpoint state⟩ :: rest) =
      .checkpoint state :: casRun next rest := by simp [casRun]

theorem cas_device_write_does_not_rebase (expected ignored : String) (target : Target) (value : Nat)
    (rest : List GuardedRestoreEffect) :
    casRun expected (⟨expected, ignored, .write target value⟩ :: rest) =
      .write target value :: casRun expected rest := by simp [casRun]

theorem cas_conflict_after_pending_preserves_pending_only (expected pending : String)
    (step : GuardedRestoreEffect) (rest : List GuardedRestoreEffect) (h : step.observedFingerprint ≠ pending) :
    casRun expected (⟨expected, pending, .checkpoint .pending⟩ :: step :: rest) = [.checkpoint .pending] := by
  simp [casRun, h]

theorem cas_mismatched_removal_never_discards (expected observed next : String)
    (h : observed ≠ expected) : casRun expected [⟨observed, next, .remove⟩] = [] := by simp [casRun, h]

-- Completion includes all target chains and other deactivation work. This is a
-- caller-supplied predicate, not a proof of the whole routine's completion.
def removalPlan (allWorkComplete : Bool) : List RestoreEffect :=
  if allWorkComplete then [.remove] else []

theorem incomplete_work_never_discards_record : removalPlan false = [] := rfl

inductive Operation where
  | activate | deactivate
  deriving DecidableEq, Repr

def failureBlocked (code : String) (op : Operation) : Bool :=
  decide (code = "brightness-unavailable" ∧ op = .activate)

theorem only_unavailable_activation_is_blocked (code : String) (op : Operation) :
    failureBlocked code op = true ↔ code = "brightness-unavailable" ∧ op = .activate := by
  simp [failureBlocked]

def retainBlock (blocked conditionTrue sameRevision manualSuccess : Bool) : Bool :=
  blocked && conditionTrue && sameRevision && !manualSuccess

theorem matching_true_condition_retains_block : retainBlock true true true false = true := rfl
theorem false_edge_resets_block (blocked revision success : Bool) :
    retainBlock blocked false revision success = false := by simp [retainBlock]
theorem revision_change_resets_block (blocked condition success : Bool) :
    retainBlock blocked condition false success = false := by simp [retainBlock]
theorem manual_success_resets_block (blocked condition revision : Bool) :
    retainBlock blocked condition revision true = false := by simp [retainBlock]

-- Capped backoff for a blocked (typed capability) activation failure:
-- 1, 2, 5, then 10 minutes, indexed by consecutive attempts (0 counts as 1).
def blockedBackoffMs (attempts : Nat) : Int :=
  if attempts ≤ 1 then 60000
  else if attempts = 2 then 120000
  else if attempts = 3 then 300000
  else 600000

theorem blocked_backoff_bounded (attempts : Nat) :
    0 < blockedBackoffMs attempts ∧ blockedBackoffMs attempts ≤ 600000 := by
  unfold blockedBackoffMs
  by_cases h1 : attempts ≤ 1
  · simp [h1]
  · by_cases h2 : attempts = 2
    · simp [h2]
    · by_cases h3 : attempts = 3
      · simp [h3]
      · simp [h1, h2, h3]

def retryDelay (op : Operation) (blocked : Bool) (attempts : Nat) (retryMs : Int) : Int :=
  if op = .activate ∧ blocked = true then blockedBackoffMs attempts else retryMs

-- running means an identical id AND operation are currently in flight.
-- Caller still supplies desired transitions and handles reset/ownership rules.
def retryAllowed (running hasFailure sameOperation sameRevision blocked : Bool)
    (op : Operation) (attempts : Nat) (elapsed retryMs : Int) : Bool :=
  !running && !(hasFailure && sameOperation && sameRevision &&
    decide (elapsed < retryDelay op blocked attempts retryMs))

theorem running_job_not_duplicated (present opMatch rev blocked : Bool)
    (op : Operation) (attempts : Nat) (elapsed retryMs : Int) :
    retryAllowed true present opMatch rev blocked op attempts elapsed retryMs = false := by
  simp [retryAllowed]

theorem blocked_activation_waits_for_backoff (attempts : Nat) (elapsed retryMs : Int)
    (h : elapsed < blockedBackoffMs attempts) :
    retryAllowed false true true true true .activate attempts elapsed retryMs = false := by
  simp [retryAllowed, retryDelay, h]

theorem blocked_activation_retries_after_backoff (attempts : Nat) (elapsed retryMs : Int)
    (h : blockedBackoffMs attempts ≤ elapsed) :
    retryAllowed false true true true true .activate attempts elapsed retryMs = true := by
  have hn : ¬ elapsed < blockedBackoffMs attempts := by omega
  simp [retryAllowed, retryDelay, hn]

-- Eligibility only: a blocked activation is never suppressed for longer than
-- the cap. Whether the service then runs it (liveness) is not modeled.
theorem blocked_activation_eligible_after_cap (attempts : Nat) (elapsed retryMs : Int)
    (h : 600000 ≤ elapsed) :
    retryAllowed false true true true true .activate attempts elapsed retryMs = true := by
  have hb := (blocked_backoff_bounded attempts).2
  exact blocked_activation_retries_after_backoff attempts elapsed retryMs (by omega)

theorem deactivation_ignores_blocked (blocked : Bool) (attempts : Nat) (elapsed retryMs : Int) :
    retryAllowed false true true true blocked .deactivate attempts elapsed retryMs
      = decide (retryMs ≤ elapsed) := by
  by_cases h : elapsed < retryMs
  · have hn : ¬ retryMs ≤ elapsed := by omega
    simp [retryAllowed, retryDelay, h, hn]
  · have hle : retryMs ≤ elapsed := by omega
    simp [retryAllowed, retryDelay, h, hle]

theorem ordinary_failure_waits (op : Operation) (attempts : Nat) (elapsed retryMs : Int)
    (h : elapsed < retryMs) :
    retryAllowed false true true true false op attempts elapsed retryMs = false := by
  simp [retryAllowed, retryDelay, h]

theorem ordinary_failure_retries_at_boundary (op : Operation) (attempts : Nat) (retryMs : Int) :
    retryAllowed false true true true false op attempts retryMs retryMs = true := by
  simp [retryAllowed, retryDelay]

theorem ordinary_failure_retries_after_boundary (op : Operation) (attempts : Nat) (elapsed retryMs : Int)
    (h : retryMs ≤ elapsed) :
    retryAllowed false true true true false op attempts elapsed retryMs = true := by
  have hn : ¬ elapsed < retryMs := by omega
  simp [retryAllowed, retryDelay, hn]

theorem revision_change_allows_retry (present opMatch blocked : Bool)
    (op : Operation) (attempts : Nat) (elapsed retryMs : Int) :
    retryAllowed false present opMatch false blocked op attempts elapsed retryMs = true := by
  simp [retryAllowed]

theorem different_operation_allows_retry (present rev blocked : Bool)
    (op : Operation) (attempts : Nat) (elapsed retryMs : Int) :
    retryAllowed false present false rev blocked op attempts elapsed retryMs = true := by
  simp [retryAllowed]

theorem cleared_failure_allows_retry (opMatch rev blocked : Bool)
    (op : Operation) (attempts : Nat) (elapsed retryMs : Int) :
    retryAllowed false false opMatch rev blocked op attempts elapsed retryMs = true := by
  simp [retryAllowed]

def retryAt (op : Operation) (blocked : Bool) (attempts : Nat) (timestamp retryMs : Int) : Int :=
  timestamp + retryDelay op blocked attempts retryMs

theorem blocked_activation_retry_time (attempts : Nat) (timestamp retryMs : Int) :
    retryAt .activate true attempts timestamp retryMs = timestamp + blockedBackoffMs attempts := by
  simp [retryAt, retryDelay]
theorem deactivation_keeps_retry_time (blocked : Bool) (attempts : Nat) (timestamp retryMs : Int) :
    retryAt .deactivate blocked attempts timestamp retryMs = timestamp + retryMs := by
  simp [retryAt, retryDelay]

#print axioms external_zero_normalized
#print axioms internal_zero_preserved
#print axioms invalid_availability_field_rejected
#print axioms absent_or_empty_name_never_falls_back
#print axioms named_request_uses_checked_name
#print axioms reservation_contract
#print axioms checkpoint_contract
#print axioms failed_preflight_blocks_all_effects
#print axioms failed_reservation_prevents_all_effects
#print axioms preflight_and_reservation_precede_all_effects
#print axioms stateless_preflight_without_reservation
#print axioms end_only_brightness_reserves_target
#print axioms receipt_requires_exit_readback_and_persistence
#print axioms receipt_preserves_pin_and_values
#print axioms failed_brightness_checkpoint_preserves_earlier_effects
#print axioms brightness_checkpoint_precedes_its_write
#print axioms confirmed_receipt_follows_its_write
#print axioms unavailable_live_target_holds
#print axioms mismatched_live_target_holds
#print axioms pending_before_marks_done_without_write
#print axioms pending_applied_retries
#print axioms pending_ambiguous_holds_even_if_activation_confirmed
#print axioms confirmed_manual_change_skips_target
#print axioms unconfirmed_ambiguous_value_holds
#print axioms unconfirmed_before_marks_done
#print axioms fresh_applied_requests_before
#print axioms any_write_is_pinned
#print axioms legacy_binding_never_confirms
#print axioms held_read_has_no_record_or_device_effect
#print axioms failed_pending_checkpoint_prevents_restore_write
#print axioms pending_receipt_precedes_restore_write
#print axioms failed_restore_confirmation_leaves_pending
#print axioms confirmed_restore_persists_done_after_write
#print axioms mark_done_has_no_device_write
#print axioms failed_skip_commit_preserves_all_entries
#print axioms skipped_same_target_entry_never_resumes
#print axioms committed_skip_completes_all_same_target_entries
#print axioms skip_commit_preserves_other_targets
#print axioms stopped_target_pass_never_runs_older
#print axioms uncertainty_stops_older_target_entries
#print axioms manual_override_stops_older_target_entries
#print axioms failed_write_stops_older_target_entries
#print axioms failed_finish_receipt_stops_older_target_entries
#print axioms cas_conflict_prevents_all_further_effects
#print axioms cas_checkpoint_carries_new_fingerprint
#print axioms cas_device_write_does_not_rebase
#print axioms cas_conflict_after_pending_preserves_pending_only
#print axioms cas_mismatched_removal_never_discards
#print axioms incomplete_work_never_discards_record
#print axioms only_unavailable_activation_is_blocked
#print axioms matching_true_condition_retains_block
#print axioms false_edge_resets_block
#print axioms revision_change_resets_block
#print axioms manual_success_resets_block
#print axioms running_job_not_duplicated
#print axioms blocked_backoff_bounded
#print axioms blocked_activation_waits_for_backoff
#print axioms blocked_activation_retries_after_backoff
#print axioms blocked_activation_eligible_after_cap
#print axioms deactivation_ignores_blocked
#print axioms ordinary_failure_waits
#print axioms ordinary_failure_retries_at_boundary
#print axioms ordinary_failure_retries_after_boundary
#print axioms revision_change_allows_retry
#print axioms different_operation_allows_retry
#print axioms cleared_failure_allows_retry
#print axioms blocked_activation_retry_time
#print axioms deactivation_keeps_retry_time

def operationName : Operation → String
  | .activate => "activate"
  | .deactivate => "deactivate"

end OmachordBrightness

-- Finite safe-integer vectors, executed independently against Conditions.js.
def main : IO Unit := do
  let bools := [false, true]
  let ops := [OmachordBrightness.Operation.activate, .deactivate]
  for running in bools do
    for present in bools do
      for sameOp in bools do
        for sameRev in bools do
          for blocked in bools do
            for op in ops do
              for attempts in ([1, 4] : List Nat) do
                for elapsed in ([-1000000, -1, 0, 1, 59999, 60000, 299999, 300000, 300001, 599999, 600000, 1000000] : List Int) do
                  let allowed := OmachordBrightness.retryAllowed running present sameOp sameRev blocked op attempts elapsed 300000
                  IO.println s!"RETRY {running} {present} {sameOp} {sameRev} {blocked} {OmachordBrightness.operationName op} {attempts} {elapsed} {allowed}"
  for op in ops do
    for blocked in bools do
      for attempts in ([1, 4] : List Nat) do
        for timestamp in ([-1000000, 0, 1700000000000] : List Int) do
          for retryMs in ([0, 300000] : List Int) do
            let retryAt := OmachordBrightness.retryAt op blocked attempts timestamp retryMs
            IO.println s!"DESCRIPTION {OmachordBrightness.operationName op} {blocked} {attempts} {timestamp} {retryMs} {retryAt}"
