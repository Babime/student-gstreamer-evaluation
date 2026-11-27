# Contributions

## Team members

- Nassim Mahnane (single-member team)

## Contributions

| Member | Work |
|---|---|
| Nassim Mahnane | Pipeline design and `scripts/sender.sh`; native sender `src/monitor_sender.c` (CLI, bus handling, EOS, timed stop, headless mode, dynamic brightness); RTP receiver and playback scripts; recording branch; `verify.sh`, `build.sh`, `clean.sh`; debugging investigation; H.264 vs JPEG experiment; all documentation. |

## Tests performed

| Member | Tests |
|---|---|
| Nassim Mahnane | `clean.sh` → `build.sh` → `verify.sh` run twice in a row; invalid-argument cases; shell sender stopped with Ctrl-C (EOS) and recording checked with `gst-discoverer-1.0`; receiver in test mode (frame count); recordings stopped with/without EOS (debug report); 2 × 45 s experiment runs. |

## Reviews

| Component | Reviewed by |
|---|---|
| Native sender | Nassim Mahnane |
| RTP transmission / receiver | Nassim Mahnane |
| Recording / diagnostics / verification | Nassim Mahnane |
