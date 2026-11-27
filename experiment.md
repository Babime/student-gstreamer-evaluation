# Engineering experiment: H.264/RTP versus JPEG/RTP

## Question

For the network branch of the monitoring sender, what does switching the
codec from H.264 (`x264enc` + `rtph264pay`) to JPEG (`jpegenc` + `rtpjpegpay`)
change in network data rate and sender CPU usage?

## Hypothesis

JPEG compresses each frame independently (intra-only), so it should need a
clearly higher bitrate than H.264, which uses inter-frame prediction; in
exchange `jpegenc` should cost less CPU than `x264enc`.

## Configurations

| | A-h264 | B-jpeg |
|---|---|---|
| Network encoder | `x264enc tune=zerolatency speed-preset=ultrafast key-int-max=20` (default target bitrate 2048 kbit/s) | `jpegenc quality=85` |
| Payloader | `rtph264pay config-interval=1 pt=96` | `rtpjpegpay pt=26` |

Only the network codec changes (`monitor_sender --codec h264|jpeg`).

## Controlled variables

Same binary and pipeline otherwise: `smpte` pattern, 800×450, 10 fps, same
overlays and dynamic brightness, headless preview (`fakesink`), identical
recording branch (H.264/Matroska), port 5123, duration 45 s per run, same
machine (12-CPU laptop, Ubuntu 24.04 in WSL2), runs executed one after the other.

## Measurement method

`./scripts/run-experiment.sh` (raw logs in `artifacts/experiment/`):

- **Network data rate**: a separate `gst-launch-1.0 -v udpsrc port=5123 ! fakesink silent=false`
  receives the RTP packets without decoding; each packet produces one
  `last-message = chain ... (N bytes` line. Packets and bytes are summed;
  rate = bytes × 8 / 45 s (RTP payload + RTP header, without UDP/IP headers).
- **CPU**: `pidstat -u -p <monitor_sender pid> 1` during the run, average of the
  per-second `%CPU` (100 % = one core). It covers the whole sender, including
  the recording encoder, which is identical in both runs.
- **Startup time**: time between launching the process and the
  `Pipeline is PLAYING` line in the sender log (log polled every 20 ms).
- **Warnings**: `WARNING` lines in the sender log.
- **Recording size**: control value, must be similar in both runs.

## Results (`evidence/measurements.csv`)

| | A-h264 | B-jpeg | B / A |
|---|---|---|---|
| RTP packets (45 s) | 11 545 | 14 017 | 1.21 |
| RTP bytes | 11.72 MB | 19.31 MB | 1.65 |
| Network rate | 2084 kbit/s | 3434 kbit/s | 1.65 |
| Sender CPU (avg) | 9.8 % | 6.6 % | 0.67 |
| Startup time | 118 ms | 97 ms | – |
| Warnings | 0 | 0 | – |
| Recording size (control) | 11.59 MB | 11.73 MB | 1.01 |

The recording sizes are within 1 %, confirming that the rest of the pipeline
behaved the same. The CPU difference (≈3.2 points) is therefore attributable to
the network encoder: `x264enc` costs about 1.5× more than `jpegenc` here.

## Limitations

- One run per configuration; CPU values under WSL2 fluctuate by about ±1 point.
- H.264 rate is driven by `x264enc`'s default 2048 kbit/s target, JPEG by
  `quality=85`; image quality was not measured objectively (no PSNR/SSIM), only
  visually similar. A lower H.264 bitrate would widen the gap.
- The synthetic `smpte` pattern is almost static: real camera footage (noise,
  motion) would raise both rates, JPEG more than H.264 in static scenes.
- Loopback interface: no packet loss, so error recovery was not observed;
  latency was not measured.

## Engineering conclusion

For this monitoring scenario (static scene, 800×450 @ 10 fps), H.264 needs
about 40 % less bandwidth (2.1 vs 3.4 Mbit/s) for about 1.5× the network-encoder
CPU and remains well under one core. On a constrained link (several cameras on
one uplink) H.264 is the right choice. JPEG is preferable when sender CPU is the
limit or when robustness matters more than bandwidth: every JPEG frame is
independent, so a lost packet damages only one frame, while H.264 can propagate
an error until the next keyframe (here every 2 s, which is why `key-int-max`
and `config-interval` are set). JPEG/RTP is also simpler to decode and
interoperates with any MJPEG client, whereas H.264 needs SPS/PPS signalling.
