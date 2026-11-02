# firmware/lib

Pure-logic modules (no Arduino headers) live here, one folder per module, so the
`native` environment can unit-test them on the host: pulse window, classification
and hysteresis, upload scheduler, battery percent, low-voltage sleep decision,
backoff. Added in Phase 4.
