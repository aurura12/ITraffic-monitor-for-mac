# Conservative Traffic Accounting Design

## Goal

Make the persisted traffic history conservative and auditable:

```text
final App bytes + final Clash remainder = raw nettop bytes
```

The equality must hold for every finalized sampling window and separately for
download and upload. The attribution layer may move bytes from the raw Clash
row to an App only when the same window contains enough raw Clash bytes.

## Metric definition

The authoritative metric is the byte count emitted by `nettop -t external`.
That means non-loopback interface socket traffic as defined by macOS; it is not
promised to be physical Wi-Fi/Ethernet usage. A TUN interface may therefore be
part of this metric. The UI and documentation must use wording consistent with
this definition.

## Accounting rules

1. The nettop frame is the only source allowed to create counted bytes.
2. Clash API data is an attribution declaration only; it never adds bytes.
3. A declaration may transfer at most the raw Clash bytes in the same
   reconciliation window, independently for download and upload.
4. A missing process, failed port mapping, short-lived connection, mismatched
   timestamp, or API/nettop mismatch leaves bytes in the Clash row.
5. No utun difference, proportional allocation, foreground fallback, or
   cross-window debt participates in persisted accounting.
6. Protocol overhead, retransmissions, DNS, keepalive, and other bytes that
   cannot be mapped one-to-one remain in Clash.
7. A live view may display tentative attribution, but only finalized windows
   are written to historical accounting.

## Data flow

```text
nettop frame
    ├── raw App rows ────────────────┐
    └── raw Clash row ── declarations ── bounded same-window transfers
                                      ├── confirmed App additions
                                      └── untransferred Clash remainder
                                                    │
                                           finalized sample ledger
```

The settlement function is pure and returns both final rows and a conservation
result. It rejects negative values and clamps transfers to the available raw
Clash budget. Unused declarations are discarded at window finalization rather
than carried as debt.

## Persistence

Each captured frame is stored as an idempotent sample. The sample ledger stores
the raw totals, capture timestamp, bucket metadata, and final allocations. All
final rows—including the Clash remainder—are stored in `sample_allocations`, so
the invariant can be checked directly from SQLite.

The sample identifier is supplied by the capture path and reused if the same
sample is retried. A transaction inserts the sample, replaces its allocations,
and marks it finalized atomically. A finalized sample with the same identifier
is a no-op. This prevents replayed frames from inflating totals and prevents a
crash from leaving a half-written sample visible to history queries.

The existing minute table remains readable for backward compatibility. New
samples use the ledger, and read queries combine legacy rows with finalized
ledger allocations. This avoids rewriting existing user history during the
cutover.

## Migration and failure behavior

- Existing `app_traffic` rows are treated as legacy finalized history.
- New writes do not append to the legacy minute table.
- A sample is visible in history only after its allocation transaction is
  finalized.
- If attribution cannot be confirmed, the raw Clash remainder is persisted;
  the sample is never enlarged to compensate for an attribution failure.
- The current minute is queryable because every finalized frame is persisted,
  rather than being held only in an in-memory minute accumulator.

## Non-goals

- This design does not promise that every VPN byte can be assigned to the
  correct App with the available nettop and Clash API data.
- It does not redefine `nettop -t external` as physical interface usage.
- It does not make the Network Extension path authoritative until that path is
  enabled and independently validated.

## Verification requirements

Tests must cover:

- per-window and per-direction conservation;
- declarations larger than the Clash budget;
- no process/port match leaving the Clash remainder untouched;
- no cross-window debt or foreground fallback;
- repeated sample commits being idempotent;
- current-minute queries including finalized samples;
- legacy rows remaining readable after schema migration.
