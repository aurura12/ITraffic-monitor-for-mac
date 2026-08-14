# VPN / proxy traffic attribution repair

## Goal

Keep delayed app attribution for Clash, Clash Verge, and Surge traffic while
preventing a missing `nettop` proxy row or a socket-port collision from sending
bytes to the wrong app.

## Design

The attributor keeps credits produced by proxy-controller snapshots in a
timestamped FIFO. A `nettop` frame consumes credits only when it contains the
corresponding proxy process row. Consumption is capped independently for upload
and download by that row's observed bytes and takes credits from oldest to
newest. A credit remains available for a later proxy row, but expires after ten
seconds; expiry emits a diagnostic and leaves the bytes on the proxy rather
than retroactively attributing them.

Socket ownership is keyed by transport protocol plus local source port. The
controller connection model decodes its protocol when supplied. A connection
without protocol does not use a port-based owner lookup; it can still use the
controller's process metadata. This avoids treating an unrelated TCP socket as
the owner of UDP/QUIC traffic sharing the same numeric port.

## Error handling and observability

Expired credits and unmapped connections are logged. Missing proxy rows remain
a recoverable state and do not reset the queue. Controller disappearance,
authentication failure, or explicit disable still reset it.

## Tests

Unit tests will verify FIFO delayed consumption, expiry, independent
directional capping, and TCP/UDP same-port ownership. Existing proxy tests must
continue to pass.
