# Video monitoring system (GStreamer)

Team: **Nassim Mahnane**

## Quick evaluation

```bash
git clone <repository>
cd student-gstreamer-evaluation
./scripts/clean.sh
./scripts/build.sh
./scripts/verify.sh
```

`verify.sh` returns 0 when every check passes. The result is printed at the end
and saved in `artifacts/verification-summary.txt`.

- Expected build time: under 10 s
- Expected verification time: about 25 s (sender runs 15 s)

## Dependencies

Ubuntu 24.04 (tested in WSL2 with WSLg; the Codespaces image provides the same packages):

```bash
sudo apt-get install -y gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-base-apps \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
  gstreamer1.0-x gstreamer1.0-gl libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  build-essential cmake pkg-config graphviz sysstat
```

(`x264enc` comes from plugins-ugly, `avdec_h264` from libav, `gst-discoverer-1.0`
from plugins-base-apps, `pidstat` from sysstat, `dot` from graphviz.)

## Assigned configuration

`config/team.conf`:

| Parameter | Value |
|---|---|
| Pattern | smpte |
| Resolution | 800×450 |
| Frame rate | 10 fps |
| RTP/UDP port | 5123 |
| Overlay position | top-center |
| Recording container | Matroska (`.mkv`) |
| Network codec | H.264 |
| Runtime | 60 s |

## Generated artifacts

Everything generated goes to `build/` (binary) and `artifacts/`:
`build.log`, `sender.log`, `receiver.log`, `verification.log`,
`verification-summary.txt`, `test-recording.mkv`, `dot/` (pipeline graph),
`experiment/` (experiment logs). `./scripts/clean.sh` removes both directories.

## Running the system manually

Use two terminals, from the repository root, after `./scripts/build.sh`.

Graphical network receiver (start it first):

```bash
./scripts/receiver.sh display
```

Native sender with graphical preview, for the assigned runtime:

```bash
./build/monitor_sender --pattern smpte --width 800 --height 450 --fps 10 --port 5123 \
    --output artifacts/recording.mkv --duration 60
```

Without `--duration` it runs until Ctrl-C, which also sends EOS and finalizes the file.
Add `--headless` to replace the preview window by a `fakesink`. `--help` lists all options
(`--codec h264|jpeg`, `--overlay-position`, `--team`).

Command-line (gst-launch) version of the sender, Part 1 (Ctrl-C to stop, recording in
`artifacts/sender-recording.mkv`):

```bash
./scripts/sender.sh            # or: ./scripts/sender.sh --headless
```

Receiver in test mode (no window, prints one line per decoded frame):

```bash
./scripts/receiver.sh test
```

Play the recording:

```bash
./scripts/play-recording.sh                       # artifacts/test-recording.mkv
./scripts/play-recording.sh recordings/sample.mkv
```

Engineering experiment (about 2 minutes, writes `evidence/measurements.csv`):

```bash
./scripts/run-experiment.sh
```

Pipeline graph: `verify.sh` runs the sender with `GST_DEBUG_DUMP_DOT_DIR=artifacts/dot`;
`evidence/pipeline.png` was produced with
`dot -Tpng artifacts/dot/monitor_sender_playing.dot -o evidence/pipeline.png`.

## Dynamic property

Every 5 seconds `monitor_sender` changes the **`brightness`** property of the
**`videobalance` element named `video_balance`** (cycle 0.20 → -0.20 → 0.00),
without rebuilding the pipeline. Each change is logged, in headless mode too:

```
DYNAMIC_PROPERTY element=video_balance property=brightness value=0.20
```

## Documentation

- `architecture.md` – pipeline diagram, elements, caps, queues, EOS, modes
- `debug-report.md` – recording terminated without EOS
- `experiment.md` – H.264/RTP vs JPEG/RTP
- `CONTRIBUTIONS.md`,

## Known limitations

- The preview and the graphical receiver need a display (WSLg, or the Codespaces virtual desktop); use `--headless` / `receiver.sh test` otherwise.
- Only UDP to `127.0.0.1` is supported (as required); no RTCP, no packet-loss recovery.
- Recording containers supported: `.mkv` and `.ts`; network codecs: H.264 and JPEG.
- `verify.sh` uses port 5123: another process using this port would make the RTP test fail.
- If the sender is killed with SIGKILL the recording is not finalized (see `debug-report.md`).
