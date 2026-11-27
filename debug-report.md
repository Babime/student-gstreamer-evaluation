# Debug report: recording terminated without EOS

## 1. Observed symptom

During the first tests of the recording branch, the pipeline was started with
`gst-launch-1.0` **without `-e`** and stopped by killing the process. The
resulting `.mkv` was non-empty (2.5 MB for 10 s) but:

- `gst-discoverer-1.0` reported a duration of about **8.0 s** for a 10 s recording;
- the reported bitrate was **0**;
- players showed an unknown/incorrect total length and seeking was unreliable.

## 2. Initial hypotheses

1. The muxer never wrote its final metadata because the pipeline was not given an EOS.
2. The encoder output was wrong (caps / profile problem) — the very first
   test pipeline had no `format=I420` caps and `x264enc` chose *High 4:4:4*.
3. The disk write was incomplete (frames missing at the end of the file).

## 3. Commands used

```bash
# reproduce: same pipeline, three ways of stopping it (10 s each)
P='videotestsrc is-live=true ! video/x-raw,format=I420,width=800,height=450,framerate=10/1 ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=20 ! h264parse ! matroskamux ! filesink'
gst-launch-1.0    $P location=fault.mkv       & sleep 10; kill -9  $!   # no EOS
gst-launch-1.0    $P location=sigint-no-e.mkv & sleep 10; kill -INT $!  # no -e
gst-launch-1.0 -e $P location=fixed.mkv       & sleep 10; kill -INT $!  # EOS

gst-discoverer-1.0 fault.mkv          # duration / bitrate
GST_DEBUG="matroskademux:4" gst-launch-1.0 filesrc location=fault.mkv ! matroskademux ! fakesink
gst-inspect-1.0 matroskamux           # properties: streamable, min-index-interval
```

## 4. Log extract

```
== fault.mkv size=2553387           (kill -9)
  Duration: 0:00:08.013000001
      Bitrate: 0
== sigint-no-e.mkv size=2601567     (SIGINT, no -e)
  Duration: 0:00:08.007000001
      Bitrate: 0
== fixed.mkv size=2601966           (SIGINT with -e)
  Duration: 0:00:10.000000000
      Bitrate: 2091105
-- GST_DEBUG=matroskademux:4 on fault.mkv
WARN matroskademux ...parse_contents_seekentry: Too large SeekPosition 18446744073709551615
WARN matroskademux ...parse_contents_seekentry: Incomplete seekhead entry (0x1549a966/18446744073709551615)
WARN matroskademux ...parse_contents_seekentry: Incomplete seekhead entry (0x1654ae6b/18446744073709551615)
WARN matroskademux ...parse_contents_seekentry: Incomplete seekhead entry (0x1c53bb6b/18446744073709551615)
-- gst-launch-1.0 log, no -e:            -- with -e:
handling interrupt.                      Got EOS from element "pipeline0".
Interrupt: Stopping pipeline ...         EOS received - stopping pipeline...
```

(`0x1549a966` = Segment Info, `0x1654ae6b` = Tracks, `0x1c53bb6b` = Cues.
The same file stopped with EOS produces no such warning.)

## 5. Root cause

`matroskamux` writes the header first with placeholders. The SeekHead
positions, the segment **Duration** and the **Cues** (seek index) are only known
at the end; they are written when the muxer receives **EOS**. Killing the
process (or `gst-launch-1.0` without `-e`, which just sets the pipeline to NULL
on Ctrl-C) never delivers EOS to the muxer, so these elements keep their
placeholder value (`0xFFFFFFFFFFFFFFFF`). The demuxer must then estimate the
duration from the clusters it finds, which gives the wrong 8 s.

## 6. Correction

- Shell sender: `gst-launch-1.0 -e` (EOS on interrupt) — `scripts/sender.sh`.
- Native sender: on `--duration` expiry or SIGINT/SIGTERM,
  `gst_element_send_event(pipeline, gst_event_new_eos())`; the main loop is only
  left when `GST_MESSAGE_EOS` arrives on the bus, then the state is set to NULL.
- `verify.sh` stops processes with SIGINT, never `kill -9` (except as a
  last-resort timeout), and checks the discovered duration.

## 7. Why it works

EOS is a serialized event: it follows the last buffer through the queues and the
encoder. `x264enc` flushes its delayed frames, then `matroskamux` receives EOS
on its sink pad, writes the Cues, seeks back to fill in the Duration and SeekHead
entries, and forwards EOS to `filesink`. The pipeline posts EOS on the bus only
after every sink got it, so stopping the pipeline at that moment can no longer
truncate the file. The fixed file has the exact 10 s duration and a bitrate.

## 8. Alternative diagnosis considered and rejected

**"The encoder caps (High 4:4:4 profile) produced a broken file."** The first
test pipeline had no `format=I420` caps and `x264enc` chose Y444, which many
players cannot decode.

## 9. Evidence used to reject it

All three files above use exactly the same caps (`format=I420`, Constrained
Baseline). Only the stopping method changes, and only the files stopped without
EOS are wrong. The 4:4:4 issue is real but independent; it was fixed separately
by forcing `format=I420` before the tee. The "incomplete disk write" hypothesis
was rejected too: the files have nearly the same size (2.55–2.60 MB) and decode
completely; only the metadata is missing.

## 10. Reproducing the fault

```bash
mkdir -p artifacts/debug && cd artifacts/debug
gst-launch-1.0 videotestsrc is-live=true ! video/x-raw,format=I420,width=800,height=450,framerate=10/1 \
  ! x264enc tune=zerolatency ! h264parse ! matroskamux ! filesink location=fault.mkv &
sleep 10; kill -9 $!
gst-discoverer-1.0 fault.mkv | grep -E "Duration|Bitrate:"   # ~8 s, Bitrate: 0
```

Repeat with `gst-launch-1.0 -e ...` and `kill -INT $!` to see the correct result.
