# Brightness: scoped Lean verification

`test/lean/Brightness.lean` is a small, executable Lean 4 specification of the
brightness safety policy and automatic retry guard. It is **not a verified
translation of `bin/omachord`, `Conditions.js`, `Service.qml`, or `Panel.qml`**.
The model distinguishes admission, reservations, per-setter checkpoints,
attempted writes, activation confirmation, restoration progress, and guarded
record removal. None is treated as proof of a physical brightness change.

## Run locally

No additional Lean libraries, Lake project, dependency downloads, or root
`lean-toolchain` file are needed. Tested with Lean 4.34.0 and Node.js.

```sh
# Uses lean from PATH; a missing Lean or Node executable is an error, not a skip.
bash test/lean/run.sh

# Or choose an already installed Lean explicitly:
LEAN="$HOME/.local/bin/lean" bash test/lean/run.sh

# Proof checking alone, including each theorem's axiom dependencies:
lean test/lean/Brightness.lean
```

The runner checks the source and runs its finite vector generator via `lean
--run`, prints every theorem's `#print axioms` output, then checks the generated
vectors against the actual repository `Conditions.js` in Node's VM. It does not
modify production sources, desktop state, the root test runner, or CI. Temporary
output is removed on exit. `LEAN` names one executable, not a shell command.

## What the model proves

The theorems are universally quantified over their stated model inputs; they
are not just exhaustive tests of a handful of brightness percentages.
There are 65 checked theorems. On Lean 4.34.0, their printed axiom dependencies
are either empty, `[propext]`, or `[propext, Quot.sound]`; none use `sorryAx`,
`Classical.choice`, or a project-defined axiom.

| Contract | Model/theorems |
| --- | --- |
| All subprocess metadata availability fields must be booleans when present. Read and write requests require a nonempty checked name; missing/empty names never select a fallback monitor. | `invalid_availability_field_rejected`, `absent_or_empty_name_never_falls_back`, `named_request_uses_checked_name` |
| An unavailable brightness requirement declared in start **or onEnd** actions blocks the entire routine, including earlier non-brightness actions. | `requiresBrightness`, `start`, `failed_preflight_blocks_all_effects` |
| For stateful runs, successful preflight and a persisted reservation precede all abstract routine effects; failed reservation produces no effects. Any required brightness gives the reservation version 3 and `brightnessTarget`, with claims and **empty setters**. This includes end-only brightness and nonrestoring brightness even when claims are empty. | `preflight_and_reservation_precede_all_effects`, `failed_reservation_prevents_all_effects`, `reservation_contract`, `end_only_brightness_reserves_target` |
| Stateless, nonrestoring runs still preflight a declared brightness requirement but do not create a reservation/snapshot. | `stateless_preflight_without_reservation`, `failed_preflight_blocks_all_effects` |
| When a journaled brightness action is reached, its local v3 checkpoint pins monitor name plus metadata digest, records before/normalized-applied values, and starts unconfirmed. External DDC zero becomes one before this checkpoint. | `checkpoint_contract`, `external_zero_normalized`, `internal_zero_preserved` |
| That brightness checkpoint precedes **its own write**, not all routine effects. If it fails, earlier effects remain and this brightness write is not issued. Persisted confirmation follows the write. | `brightness_checkpoint_precedes_its_write`, `failed_brightness_checkpoint_preserves_earlier_effects`, `confirmed_receipt_follows_its_write` |
| Persisted confirmation requires successful setter exit **and** exact requested normalized value from the pinned target **and** successful receipt persistence. | `receipt_requires_exit_readback_and_persistence`, `receipt_preserves_pin_and_values` |
| Unavailable or mismatched live target yields a hold, with no record or device effect from that entry. | `unavailable_live_target_holds`, `mismatched_live_target_holds`, `held_read_has_no_record_or_device_effect` |
| Pending restoration with live value equal to before marks done without a device write. Pending live-applied retries a write, unless before and applied are equal (before takes priority). Pending live value different from both holds **even if activation was confirmed**. | `pending_before_marks_done_without_write`, `pending_applied_retries`, `pending_ambiguous_holds_even_if_activation_confirmed`, `mark_done_has_no_device_write` |
| A fresh confirmed entry whose live value differs from applied requests a target-wide skip. A fresh unconfirmed entry with a value different from both before/applied holds; already-before marks done. | `confirmed_manual_change_skips_target`, `unconfirmed_ambiguous_value_holds`, `unconfirmed_before_marks_done` |
| Restoring an applied value requests before only on the recorded target. Legacy target binding preserves `confirmed:false`; binding is not write confirmation. | `fresh_applied_requests_before`, `any_write_is_pinned`, `legacy_binding_never_confirms` |
| A persisted pending receipt precedes every modeled restore write; failed pending persistence prevents that write. Successful write confirmation precedes persisted done. Failed exit/readback leaves pending, rather than a false completion receipt. | `failed_pending_checkpoint_prevents_restore_write`, `pending_receipt_precedes_restore_write`, `failed_restore_confirmation_leaves_pending`, `confirmed_restore_persists_done_after_write` |
| A successful target-wide skip atomically completes all remaining same-target entries; later passes cannot resume their older writes. Other targets are unchanged. Failed skip persistence changes no entries. | `commitSkipTarget`, `committed_skip_completes_all_same_target_entries`, `skipped_same_target_entry_never_resumes`, `skip_commit_preserves_other_targets`, `failed_skip_commit_preserves_all_entries` |
| Uncertainty, manual override, failed write, or failed completion receipt stops older entries for that target for that pass. | `runTargetChain`, `stopped_target_pass_never_runs_older`, `uncertainty_stops_older_target_entries`, `manual_override_stops_older_target_entries`, `failed_write_stops_older_target_entries`, `failed_finish_receipt_stops_older_target_entries` |
| Expected snapshot fingerprint is carried from the read through each guarded operation. Successful checkpoints advance it; device writes do not rebase it. A detected conflict stops further rollback effects, including removal. | `casRun` and its five theorems; `incomplete_work_never_discards_record` |
| Failure classification blocks only `brightness-unavailable` activation. | `only_unavailable_activation_is_blocked` |
| A blocked activation with matching operation/revision never automatically retries merely because time passes. | `matching_blocked_activation_never_retried` |
| The abstract block persists on a true condition with the same revision; a false edge, revision change, or manual success resets it. | `retainBlock` and its four theorems |
| Deactivation ignores the blocked bit and retains its retry delay. Ordinary failures wait before the boundary and retry at/after it. Running identical jobs are suppressed. | `deactivation_ignores_blocked`, `ordinary_failure_*`, `running_job_not_duplicated` |
| Changed revision, different operation, or cleared failure is not suppressed by the old failure. | `revision_change_allows_retry`, `different_operation_allows_retry`, `cleared_failure_allows_retry` |
| Blocked activation has no retry timestamp; deactivation does. | `blocked_activation_has_no_retry_time`, `deactivation_keeps_retry_time` |

### Admission and activation chronology

The chronology for a stateful activation requiring start or onEnd brightness is
**preflight → v3 reservation with brightnessTarget, claims and empty setters →
routine actions**. Reservation schema selection does not depend on whether the
brightness action restores. Without a brightness requirement, the model's
reservation uses version 2 without a brightness target; that case is not the
subject of the v3 theorem.
Earlier non-brightness actions may run before the brightness action is reached.
At each journaled brightness action, the local chronology is **populated
brightness checkpoint → that brightness write → confirmed receipt, if successful**.
Failure of that local checkpoint says nothing about whether earlier routine
effects occurred and does not undo them. `start` abstracts admission of the action
list; `brightnessStep` separately models the local journaled action. These are
not a verified composition of the actual Bash control flow.

`Snapshot` is the model's projection of the v3 envelope and one populated
brightness setter entry; it is **not** the initial `Reservation`. Claims are
abstract resource identifiers. Stateless, nonrestoring activation still
preflights, but has no reservation or snapshot; the local checkpoint/receipt
theorems do not claim that all routine writes are journaled.

`receiptAfterSet` is applied to a fresh, unconfirmed brightness checkpoint.
`checkedName` models metadata **shape validation**, not the meaning of each
availability flag: false is a valid boolean, not evidence that the device is
available. The adapter must enumerate every relevant field and separately
establish capability availability. `namedBrightnessRequest` models read and
write alike, without a monitor-selection fallback.

### Restoration, retries, and record identity

`restoreDecision` is a read-only decision for one validated brightness entry.
`RestoreState.fresh` means no restoration-progress receipt yet; it is distinct
from the activation `confirmed` bit. Done/skipped entries are already complete.
The write chronology is **read/decide → persist pending → recheck record ownership
→ attempt pinned restore write → confirm exit and exact readback → persist done**.
A skip receipt follows the no-write decision. A pending retry observed at before
can persist done without reissuing a write; binding a legacy target never supplies
activation confirmation.

An **original read failure is byte-identical with respect to that operation**:
the model emits no checkpoint, device write, or removal. This is not a claim that
an entire multi-entry pass is byte-identical if earlier entries or a legacy bind
already wrote receipts, nor a proof of JSON serialization. In contrast, **a
restore-write failure after successful pending persistence intentionally changes
the record by adding/updating its pending receipt**. It must not be tested as
byte-identical to the pre-attempt record. Failure to persist done also leaves
pending. No per-entry restore step removes the snapshot.

`commitSkipTarget` models one all-or-nothing replacement marking every not-done
entry for the target skipped, not a sequence of individual commits. Its success
is conditioned on persistence and the fingerprint guard. `runTargetChain`
models a newest-first list for **one target** and stops older entries on failure
or uncertainty. A persisted target-wide skip is durable across later passes;
a failed skip commit only stops the current pass and does not pretend a durable
skip exists. Other targets may still progress in the production loop.

`casRun` consumes proposed guarded effects, starting with the fingerprint from
the snapshot read (including a read of a pending recovery record). Checkpoints
and target-wide skip receipts supply the next expected fingerprint; a device
write leaves it unchanged. A mismatch stops the entire remaining plan, so no
later checkpoint, rollback write, or removal is authorized. A conflict after
pending leaves only the **earlier pending event in our trace**; it does not assert
that a concurrent writer's actual bytes still equal that receipt. Removal has
the same fingerprint guard and a separate all-work-complete admission predicate.

These are small, separate policy abstractions. The caller supplies truthful
observations, persistence outcomes, entry ordering, operation plans and tokens.
There is no proved composition of the actual Bash implementation, no concrete
CAS/filesystem primitive in Lean, and no proof of atomicity against changes
between an ownership check and an external device operation. `bindLegacy` proves
only the constructed record's target/confirmation policy, not parsing or safe
migration of arbitrary legacy JSON.

## Connection to actual JavaScript

`test/lean/conditions-conformance.mjs` reads the actual `reconcileJobs` and
`describeFailure` functions without modifying them. The expectations come from
executing the Lean definitions, not a second JS implementation of the guard.

The generator supplies **512 retry vectors**: both operations, all combinations
of identical in-flight job / failure presence / matching operation / matching
revision / blocked bit, and elapsed times `-1000000`, `-1`, `0`, `1`, `299999`,
`300000`, `300001`, and `1000000` milliseconds. The 5-minute boundary is checked
on both sides and exactly at equality, including a backwards clock movement.
Node replays those at timestamps zero and `1700000000000`, and when not running
also with an unrelated operation or routine in flight: **2048 scheduling
comparisons**. Another **24 vectors** check `describeFailure` for both operations,
both blocked values, three timestamps, and zero/5-minute retry delays. Missing,
duplicate, or truncated vector output fails the test.

This is finite conformance evidence for those two JS functions, not a proof for
all JavaScript inputs. Inputs use safe integers and valid operation strings;
malformed JSON, `NaN`, coercion corner cases, queue truncation, multiple desired
transitions, revision hashing, and service lifecycle/restart behavior are outside
this comparison. Classification and block reset are **model-only proofs** here;
they are not connected to `Service.qml` by this runner. Service/QML and Bash
integration tests remain necessary.

## Explicit assumptions and non-claims

- Declaration discovery is complete: the caller knows all start and onEnd
  brightness requirements before admitting **any** routine actions. The arbitrary list of
  action identifiers abstracts routine effects, not their concrete Bash control
  flow or correctness. Undeclared brightness actions are outside the contract.
- Capability discovery returns truthful, valid, readable/writable target
  information after checking every metadata availability field and the name.
  Monitor names and metadata digests are treated as exact identity
  tokens; digest collision resistance and device identity uniqueness are not
  proved.
- Target identity remains stable across validation, read, write, and readback,
  or the implementation detects the change before a write. There is no proof of
  atomicity against hotplug, monitor replacement, concurrent brightness changes,
  or adversarial tools. Equality-based restore cannot detect a user changing the
  value away and back to the same number (the ABA problem).
- External commands report truthful status; observations correspond to the
  pinned target and accurately report its value. A successful exit without exact
  readback is deliberately insufficient. Driver/DDC behavior, readback latency,
  physical luminance and helper implementations are not verified.
- Reservation/checkpoint/receipt persistence and record removal are represented
  by success inputs and guarded effect traces. Fingerprint equality is exact
  token equality; generating the token from the intended bytes and detecting
  concurrent mutation are implementation obligations. Filesystem atomicity,
  crash ordering, locks, partial writes, process cancellation, and durable
  storage are not proved. A rejected CAS cannot authorize further modeled
  effects, but no theorem undoes effects that preceded detection. Failed
  persistence cannot create a successful receipt event in the model.
- Percentage validation is outside the model. Natural-number values stand for
  validated values; only the external-DDC zero-to-one normalization is modeled.
- Scheduling uses mathematical integers; the finite JS comparison stays within
  the safe-integer range. Desired transitions, conditions, revision generation,
  ownership, resets across service restart and liveness are caller obligations.
- There are no `sorry`, `admit`, custom unproved axioms, or `native_decide` proofs.
  The source prints dependencies for every theorem so the trusted logical basis
  is visible rather than implied to be empty. Standard Lean logical axioms may
  occur; external-tool and atomicity assumptions remain explicit *model inputs*,
  not extra Lean axioms that conceal missing implementation proofs.
