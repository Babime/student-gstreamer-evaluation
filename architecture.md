# Architecture

Team configuration (`config/team.conf`): `smpte`, 800×450, 10 fps, RTP/UDP port 5123,
overlay top-center, Matroska recording, H.264 network codec, runtime 60 s.

## 1. Sender diagram

```
videotestsrc (source, is-live=true, pattern=smpte)
      |  video/x-raw,width=800,height=450,framerate=10/1
videoconvert (source_convert)
      |
videobalance (video_balance)        <- brightness changed every 5 s
      |
textoverlay (team_overlay)          "Nassim Mahnane | 800x450 @ 10 fps", top-center
      |
timeoverlay (time_overlay)          running time, bottom-left
      |
videoconvert (output_convert)
      |  video/x-raw,format=I420,width=800,height=450,framerate=10/1   (RAW)
     tee (split)
   /        |                     \
  |         |                      |
queue     queue                  queue
(preview_ (recording_queue)      (network_queue)
 queue)     |                      |
  |       x264enc                x264enc (network_encoder)
videoconvert (recording_encoder)   |  video/x-h264 (COMPRESSED)
  |         |  video/x-h264      rtph264pay (rtp_payloader, pt=96)
autovideosink h264parse            |  application/x-rtp
 or fakesink  (recording_parser) udpsink (rtp_sink) -> 127.0.0.1:5123
 (headless)   |
           matroskamux (recording_muxer)
              |  video/x-matroska
           filesink (recording_sink) -> artifacts/test-recording.mkv

  Branch A: preview     Branch B: recording     Branch C: RTP/UDP transmission
```

The graph generated from the running pipeline (`GST_DEBUG_DUMP_DOT_DIR`) is in
`evidence/pipeline.png`.

Receiver (`scripts/receiver.sh`):

```
udpsrc port=5123 caps=application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96
  -> rtpjitterbuffer -> rtph264depay -> h264parse -> avdec_h264 -> videoconvert
  -> autovideosink (display mode) | fakesink silent=false (test mode)
```

## 2. Main elements

| Element | Purpose |
|---|---|
| `videotestsrc` | Live synthetic video source (`is-live=true` so it produces frames in real time like a camera). |
| capsfilter after source | Forces the assigned resolution and frame rate. |
| `videoconvert` | Converts pixel formats between elements that do not share one. |
| `videobalance` | Brightness/contrast/saturation; used for the dynamic property. |
| `textoverlay` | Draws the team member names and the configured resolution/frame rate. |
| `timeoverlay` | Draws the running time of the stream. |
| `tee` | Duplicates each raw buffer to the three branches. |
| `queue` | Starts a new streaming thread for each branch (see §6). |
| `autovideosink` / `fakesink` | Preview window / discard frames in headless mode. |
| `x264enc` | H.264 software encoder (`tune=zerolatency`, `speed-preset=ultrafast`, keyframe every 2 s). |
| `h264parse` | Parses the H.264 byte stream and provides the stream headers (codec_data) and frame boundaries required by the muxer. |
| `matroskamux` | Packs the H.264 frames into the Matroska container with timestamps, headers and an index. |
| `filesink` | Writes the muxed bytes to the file. |
| `rtph264pay` | Splits H.264 access units into RTP packets (RFC 6184), adds RTP headers; `config-interval=1` re-sends SPS/PPS every second so a receiver can join at any time. |
| `udpsink` | Sends the RTP packets to 127.0.0.1:5123. |
| `udpsrc` / `rtpjitterbuffer` / `rtph264depay` / `avdec_h264` | Receiver: UDP reception, packet reordering/timing, RTP to H.264 reassembly, decoding. |

## 3. Raw-video caps before the tee

```
video/x-raw, format=I420, width=800, height=450, framerate=10/1
```

I420 is fixed before the tee so both encoders and the preview receive the same
format, and so `x264enc` produces 4:2:0 (Constrained Baseline) streams that every
decoder accepts.

## 4. Transmission

- Codec: H.264 (`x264enc`, zerolatency, ultrafast, `key-int-max=20`)
- RTP payload: `rtph264pay`, dynamic payload type 96, clock-rate 90000, `encoding-name=H264`
- Transport: UDP to `127.0.0.1`, port **5123**

## 5. Recording

- Codec: H.264 (`x264enc`, separate encoder instance from the network branch)
- Parser: `h264parse`
- Container: Matroska (`matroskamux`), file `artifacts/test-recording.mkv`

## 6. Queues

A `tee` pushes each buffer to its source pads one after the other in the
upstream thread. Without queues, a slow branch (the window sink waiting for the
clock, or an encoder) would block that thread and therefore all branches.

- `preview_queue` (`max-size-buffers=5 leaky=downstream`): the preview runs in
  its own thread; if the display is slow, old frames are dropped instead of
  blocking the recording and the network branch. Losing preview frames is
  acceptable, losing recorded frames is not.
- `recording_queue`: decouples the encoder + muxer + disk writes from the source.
  It is not leaky: every frame must reach the file.
- `network_queue`: decouples the second encoder and the network output, so the
  RTP stream does not wait for the recording encoder and vice versa.

Each queue also lets the two `x264enc` instances run in parallel on different
CPU cores.

## 7. How the receiver reconstructs the stream

1. `udpsrc` receives UDP datagrams. They carry no type information, so explicit
   RTP caps are given (media, clock-rate, encoding-name, payload type); without
   them the depayloader cannot be linked (caps negotiation fails).
2. `rtpjitterbuffer` reorders packets by sequence number and removes network jitter.
3. `rtph264depay` removes the RTP headers and reassembles the fragmented NAL units
   (FU-A) into complete H.264 access units. An encoder produces compressed video;
   a payloader only cuts it into packets with RTP headers, so the receiver needs
   the inverse operation (depayloader) before the decoder.
4. `h264parse` + `avdec_h264` decode to raw video; `videoconvert` adapts the format
   for the sink.

Raw video: from `videotestsrc` to the tee and in the preview branch; on the
receiver after `avdec_h264`. Compressed video: after each `x264enc`
(H.264 elementary stream, then Matroska or RTP packets) and on the receiver
until `avdec_h264`.

## 8. Recording finalisation

When `--duration` expires (or on SIGINT/SIGTERM) the application calls
`gst_element_send_event(pipeline, gst_event_new_eos())`. The EOS travels
through every branch; `matroskamux` then writes the final duration, the
cue index (seek table) and updates the SeekHead at the start of the file.
Once all sinks have received EOS, the bus posts `GST_MESSAGE_EOS`; only then does
the application leave the main loop, set the pipeline to `NULL` and exit with 0.
For the shell sender, `gst-launch-1.0 -e` converts Ctrl-C into the same EOS.
`debug-report.md` shows what happens without EOS.

## 9. Normal mode vs test mode

| | Normal mode | Test / headless mode |
|---|---|---|
| Sender preview | `autovideosink` window | `fakesink sync=true` (`--headless`) |
| Sender recording / RTP | active | active (identical) |
| Sender end | Ctrl-C (EOS) or `--duration` | `--duration` (verify.sh uses 15 s) |
| Receiver output | `autovideosink` window (`receiver.sh display`) | `fakesink silent=false` with `gst-launch-1.0 -v` (`receiver.sh test`): one `last-message = chain` line per decoded frame, counted by `verify.sh` |

Dynamic property changes are always printed as
`DYNAMIC_PROPERTY element=video_balance property=brightness value=...`.

## 10. Implementation choice: parsed pipeline (Option B)

`monitor_sender` builds a textual description from the command-line options and
calls `gst_parse_launch()`. Elements that must be controlled at run time are
named and retrieved with `gst_bin_get_by_name()` (`video_balance`).

- Advantage: the pipeline is short, readable and identical to the
  `gst-launch-1.0` command of `scripts/sender.sh`, so it can be tested on the
  command line first; tee request pads and queue linking are handled automatically.
- Limitation: errors (missing element, bad property) are only detected at run
  time when the string is parsed, the string must be escaped carefully (the
  team names are refused if they contain `"`), and dynamic changes of the
  topology (adding/removing a branch while running) are not convenient.
