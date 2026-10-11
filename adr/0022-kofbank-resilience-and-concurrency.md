# ADR 0022 - Application resilience, crash boundaries and cross-process concurrency

Date: 2026-10-09
Status: accepted (local QA scope)

## Context
Slice 2 (ADR 0021) delivered the controlled transfer flow, read-only operation
inspection and the facade security boundary. Slice 3 had to prove the claims that
the earlier twin/replay tests only sampled: what actually survives a crash, what
happens when two real OS processes contend for the same work, and whether any
reachable path can produce a second financial effect. Everything below was
established from observed behaviour against the real COBOL core, not asserted.

## Decision
1. Financial authority stays in COBOL only. The new suites inspect durable state
   (txn store, idempotency store, journal, balances, audit, events) through the
   existing KBCLI-1 verbs; no application-side ledger or recovery engine was added.

2. Operation inspection reconciles, it does not trust a frozen record.
   `GET /api/operations/:requestId` no longer treats an idempotency "C" as success
   on its own: it re-reads the transaction and journal evidence and returns an
   explicit `verdict`. A created-but-not-posted or otherwise undetermined outcome
   yields `RECONCILIATION_REQUIRED` (never retryable, never reported as done);
   a failed create with no transaction yields `NON_COMMITTED_SAFE` (retryable).
   The verdict is returned as a normal 200 body rather than a 5xx, because the
   Kof http client raises on 5xx and would hide the reconciled truth from readers.

3. Operation inspection enforces account ownership. A resolvable transaction is
   disclosed only when the caller owns the source or destination account; a guessed
   or known requestId belonging to another subject returns 403 with no txn ref.

4. CREATE is serialized by request identity in the core. `BTXNLFC` now acquires a
   `BLCK` lock keyed by a hash of the requestId (`"CR" + BHSH(requestId)`) for the
   whole `BEGIN -> create -> COMPLETE/FAIL` idempotency window and releases it on
   every exit path (including replay and mismatch). This closes the double-commit
   window where two concurrent same-requestId creates each minted their own
   transaction (observed before the fix: two transactions for one idempotency key;
   after the fix: exactly one, verified in suite H1 and a 3x repeat).

5. Crash seams are proven through the full facade path (suite G), not just the raw
   client. For each seam the committed effect, journal durability, staging state
   and the reconciled operation verdict are asserted after resuming with
   `txn.recover`:
   - ledger after-journal: balances unchanged, journal durable, recover completes,
     operation moves VISIBLE -> COMMITTED, journal written exactly once;
   - ledger after-balance: balance applied, recover completes without a second
     balance change (no double-apply), journal once;
   - ledger after-post / txn after-post: lifecycle attempt reads as
     `RECONCILIATION_REQUIRED` (never auto-retried), a repost is a core duplicate
     rejection with zero added effect, recover completes, journal and trial clean.

## Findings (recorded, not silently patched)
6. `BLCK` is not a true cross-process mutex under GnuCOBOL. Its acquire is
   `WRITE -> (INVALID KEY) READ -> REWRITE` with no OS-level record lock, and
   `LOCK IS EXCLUSIVE` either fails to open a fresh file or serializes only inside
   a single `OPEN..CLOSE`, not across processes. Consequences observed:
   - `BSEQ` (id allocation) is unguarded: N truly simultaneous `txn.create` calls
     with *distinct* requestIds can mint duplicate transaction ids; the loser's
     store write is rejected (rc 22), so the failure mode is a LOST create, never a
     phantom double-spend. Financial safety holds (trial stays balanced, store stays
     non-CORRUPT); progress under a same-instant burst is not guaranteed.
   - The requestId lock (Decision 4) and the pre-existing post/reverse locks are
     reliable for the common retry window (a second request arriving after the
     first has flushed) but share this same atomicity limit at the exact-instant
     boundary.
   A correct fix requires a real cross-process lock primitive (pre-created lock
   file opened with OS advisory locking, or moving id allocation to an atomic
   append/count store). That is a foundational change to shared infrastructure used
   by cards/PIX/collections and was deliberately NOT attempted blind in this slice.
   Suite H therefore asserts the safety invariants that always hold (no corruption,
   balanced trial, bounded progress, locks released, unique sequential ids) rather
   than encoding the race as expected behaviour.

## Consequences
- Slice 3 suites G/H/I join the make loop: `make kof-facade-test` runs A-I, 183
  end-to-end checks, 0 failed; `make test` 1627/1627; `make kof-test` 48; `make
  kof-example` OK.
- Unknown/undetermined outcomes are surfaced as data the caller must act on, never
  as an implicit success or an un-retryable dead end.
- The concurrency limitation is now visible and bounded by tests instead of being
  an unproven assumption; closing it is tracked as a separate, prerequisite infra
  decision, not a claim made here.

## Open (not claimed)
- True atomic cross-process locking for `BSEQ`/`BLCK` (lost-create under
  same-instant distinct requests).
- Lock reclaim after a hard mid-operation process kill (TTL expiry path exists but
  is not exercised end-to-end here).
- Production identity, TLS, token expiry, rate limiting (unchanged gaps).

## RESOLVED — Slice 4: real cross-process locking (supersedes Findings 6)

The deferred foundational change in Finding 6 is now implemented. `BLCK`/`BSEQ`
and the durable store writers are serialized by genuine OS locks (`flock(2)`),
not by optimistic ISAM claims. Financial authority is unchanged — COBOL still
owns every balance/ledger decision; the locks only serialize access.

Primitive. A narrow native helper `cobol/foundation/KFLOCK.c` (built to
`build/KFLOCK.so`, `RUNENV` puts `build` on `COB_LIBRARY_PATH`) is called as
`CALL "KFLOCK" USING mode, base-dir, name, status`. It `open()`s a per-name lock
file and takes a blocking or non-blocking `flock(2)`, keeping the fd in a
process-static table keyed by the resolved path so a lock stays held across COBOL
`CALL` boundaries inside one process. The kernel releases it automatically when
the process dies (normally or via `SIGKILL`). Verified empirically: cross-process
contention reports busy (61), locks survive across CALLs, process death frees
them, distinct names do not contend.

Layering.
- `BLCK` keeps the persistent `var/data/lock.idx` claim/TTL registry (so
  `ops.locks.*`, GATE4 stale-lock tests and cross-process logical holds for
  PIX/card/hold still work), but the atomic check-and-set now runs under a
  blocking registry flock (`REGISTRY-LOCKIDX`) held only for the microseconds
  needed to mutate `lock.idx`. Caller status contract unchanged (`00` acquired,
  non-`00` busy/infra).
- `BSEQ` allocates ids under a per-key flock (`SEQ-<name>`) around the
  read-increment-write. Waiting is bounded per the timeout policy below. This
  closes the duplicate-id mint from Finding 6; allocation failure now surfaces
  as a hard error to `BTXNLFC`/`BACOPN`/`BCUSTC` instead of being ignored.
- `BWR.cbl` wraps single store-file write critical sections as leaf locks
  (`KFLOCK` under the hood). A leaf lock is never held while taking another leaf
  lock, so store writers cannot deadlock. GnuCOBOL silently loses ISAM records
  when distinct keys are written concurrently to the same file, so these leaf
  locks are required for correctness, not just hygiene.

Protected writers (leaf scope, released before any onward CALL):
`WR-TXN` (`BTXNSTO` — create/lifecycle/recover/reverse), `WR-ACCT` (`BACOPN`
open, `BACSTS` update), `WR-CUST` (`BCUSTC` create, `BCUSTU`/`BCUSTS` update),
`WR-LEDGER` (`BGLPST` journal/balance/jrst/postings, `BTXNRCV` direct re-apply).
Batch/reconciliation writers run under the EOD/shutdown lifecycle gate and are
not on the online concurrent path.

Lock-order protocol (cycle-free by construction).
1. Request-identity logical lock (`BLCK` `CR+BHSH(requestId)`), then the
   transaction/hold logical lock if the operation carries one.
2. Sequence allocation lock `SEQ-<name>` — always acquired and released *inside*
   step 1, never the reverse.
3. Store leaf lock `WR-*` — outermost nesting is `logical -> SEQ -> leaf`;
   SEQ is released before a leaf is taken, and no leaf is ever taken while
   another leaf is held. Ledger posting nests one `WR-*` only around its own
   OPEN..CLOSE and releases before calling `BTXNSTO`/`BJRN`, so `WR-LEDGER` and
   `WR-TXN` are never held simultaneously.
Because the only nesting direction is logical → sequence → single leaf, no
ABBA cycle exists (this is why `LOCK IS EXCLUSIVE` across the whole multi-file
`BGLPST` OPEN was rejected: `BAL-FILE`+`GL-FILE` under one exclusive lock would
reintroduce exactly that risk).

Bounded waiting and failure semantics. `KFLOCK` mode `'W'` honours
`KOF_LOCK_TIMEOUT_MS`: when set to N>0 it polls (2ms interval) and returns the
distinct status `62` on timeout; when unset it waits in-kernel, which is safe
because the kernel releases the flock at holder death. Status codes are kept
distinguishable end to end: `00` acquired/released, `61` busy (non-blocking),
`62` timed out, `EF` infrastructure error (e.g. `KFLOCK.so` missing - the
callers fail closed with no silent fallback to the old process-local path),
`NS` invalid usage. `BSEQ` allocation failures propagate to `BTXNLFC`/`BACOPN`/
`BCUSTC`, which now hard-fail instead of minting an id from a failed
allocation.

Process-death / stale semantics. Kernel `flock` auto-release makes a hard kill
self-healing — the next process acquires immediately. The `lock.idx` TTL remains
the *logical* registry inspected by `ops.inspect`/`ops.locks.*` and expired by
`BOPSSTALE`; every `lock.idx` mutation (BLCK acquire/release and the
BOPSSTALE sweep) runs only under the registry flock, so stale entries
can no longer be lost or double-claimed, and the sweeper provably refuses to
delete a fresh live hold (scenario 11). The logical TTL is 300s: if a process
dies while holding a `lock.idx` claim (e.g. a request-identity lock), that entry
stays FRESH until expiry, so a retry with the same requestId is refused rc 24
"REQUEST IN PROGRESS" for up to 5 minutes and then proceeds; the sweeper never
overrides a FRESH entry, and nothing is ever auto-reposted - the durable state
plus the existing reconciliation verdicts decide what happened.

Test gate. `tests/concurrency.sh` (also `make concurrency-test`; part of
`make test`) drives independently launched OS processes against one shared data
directory behind a flag-file barrier, plus deterministic `KOF_CRASH` seams and a
`build/lockhelper` native driver; 44 checks, `passed=44 failed=0`, stable over
repeated runs and under the loaded `make test` sequence:
1. 12 same-instant distinct-requestId creates → 12 unique ids, 12 durable
   records (no lost create — the Finding-6 failure mode is gone).
2. 6 same-instant same-requestId identical-payload creates → one id, one record.
3. same requestId + conflicting payload → `rc=26`, zero added effect.
4. concurrent creates + list/read bursts → no crash, all records present.
5. 8 concurrent full transfer lifecycles → exact ±800000 deltas, conservation,
   `trial imbalance 0.00` (no lost balance update - `WR-LEDGER`).
6. `KOF_CRASH=AFTER-BAL` then recover → exactly-once balance, txn `PO`.
7. `SIGKILL` of workers mid-operation → next create `rc=00`, proving kernel
   lock auto-release with no permanent stall.
8. concurrent recover + create → three recoveries exactly-once, trial 0.00.
9. `KOF_CRASH=AFTER-SEQ` (new seam): identifier allocated, process interrupted
   before the record write → no partial txn in the store; restart allocation
   resumes at the next value; id gap permitted; counter >= max minted id.
10. an independent `lockhelper` process holds the registry lock; waiters with
   `KOF_LOCK_TIMEOUT_MS=150` return `62`; `bank` creates fail closed (rc 24);
    after holder exit acquisition succeeds (`00`) and creates work again;
    dlopen failure self-test returns `EF` (no silent fallback).
11. stale/override protection across processes: a fresh owner-held lock is
    visible to other processes, a wrong-owner release cannot remove it, and
    `ops.locks.release` refuses with `rc=20` while unexpired; only the owner
    release (or genuine expiry) clears it.
12. high-contention burst (12 distinct + 6 replay) followed by authoritative
    inspection: unique durable ids, replay = 1 record, `seq_TRANSACTION.dat`
    equals the highest minted id, no new journal/posting lines, trial 0.00,
    zero locks left, `ops.inspect` not `CORRUPT`.

Scope caveat. The primitive is validated on local ext4, single host, GnuCOBOL
3.1.2. On network/distributed filesystems (NFS/GPFS) `flock` semantics differ
and this design is NOT claimed to hold; multi-host would require a distributed
lock manager out of scope here.

Before/after reproduction (first executed 2026-10-10 20:42, re-executed at
21:22 and 23:33 on the same host/runtime). The Finding-6 burst is replayed by
`tests/adr0022-race-probe.sh`: 12 independently launched `bank` processes
creating distinct requestIds behind a flag-file barrier, 3 rounds per build,
asserting durable outcomes (not exit codes). Across all runs of the baseline
build (revision a04edff primitives, rebuilt in an isolated directory; see
Reproduction below), each round yielded only 2-6 accepted creates of 12, minted
duplicate ids (1-4 duplicated ids per round), 6-10 requests rejected rc 22, and
left 2-5 durable records - i.e., the lost-create race reproduced in every round.
The fixed build (commits 73c2c11/5eae401) yielded 12/12 accepted, 0
duplicate ids, 12 durable records in every round of every run. The lost-create
race described in Finding 6 no longer occurs under the supported runtime
conditions; `tests/concurrency.sh` (44 checks) and facade Suite H
`H3.concurrent.allDistinctCommit` now assert this positively and permanently.

Reproduction.
```
export PATH=/home/mel/tools/jdk-25/bin:$PATH           # class-file 69 runtime for kof targets
export KOF=/home/mel/Kof4j/bin/kof
make build && make test                                 # COBOL 1627 + tests/concurrency.sh 44
make kof-test && make kof-example && make kof-facade-test && make kof-portal
bash tests/concurrency.sh                               # 44 checks, independently launched processes
# A/B race probe (fixed side, current tree):
bash tests/adr0022-race-probe.sh "$PWD" "$PWD/build/bank" 12 3
# baseline side (isolated rebuild; a04edff predates cobol/core/, so graft the dispatcher):
git archive a04edffefb3f424b67329bc391461498764dd168 | tar -x -C /tmp/kofbase
mkdir -p /tmp/kofbase/cobol/core && cp cobol/core/BANKCLI.cbl /tmp/kofbase/cobol/core/
make -C /tmp/kofbase build
bash tests/adr0022-race-probe.sh /tmp/kofbase /tmp/kofbase/build/bank 12 3
```
The probe resets `$HOME_DIR/var/{data,journal,run}` each round (test scratch
only; point it at an isolated data directory, never at production state), uses
no pre-existing processes or leftover locks, and needs no environment beyond
`BANK_HOME`/`COB_LIBRARY_PATH` derived from its arguments.
