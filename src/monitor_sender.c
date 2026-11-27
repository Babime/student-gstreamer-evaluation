/*
 * monitor_sender - native GStreamer sender of the video monitoring system.
 *
 * Pipeline (built with gst_parse_launch, see architecture.md):
 *   videotestsrc -> caps -> videoconvert -> videobalance -> textoverlay
 *   -> timeoverlay -> raw caps -> tee
 *        tee -> queue -> preview sink (autovideosink or fakesink)
 *        tee -> queue -> encoder -> parser -> muxer -> filesink
 *        tee -> queue -> encoder -> RTP payloader -> udpsink
 */
#include <gst/gst.h>
#include <glib-unix.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

#define DYNAMIC_PROPERTY_PERIOD_SECONDS 5

typedef struct {
    const char *pattern;
    int width;
    int height;
    int fps;
    int port;
    const char *output_path;
    const char *network_codec;    /* h264 | jpeg */
    const char *overlay_position; /* top-left | top-center | bottom-right */
    const char *team_members;
    int duration_seconds;         /* 0 = run until interrupted */
    gboolean headless;
} SenderOptions;

typedef struct {
    GstElement *pipeline;
    GMainLoop *main_loop;
    GstElement *video_balance;
    gboolean eos_requested;
    gboolean eos_received;
    gboolean error_occurred;
    gboolean dot_dumped;
    guint brightness_step;
} SenderContext;

static const char *SUPPORTED_PATTERNS[] = {"smpte", "ball", "snow", "zone-plate", NULL};
static const double BRIGHTNESS_VALUES[] = {0.0, 0.20, -0.20};

static void print_usage(FILE *stream, const char *program_name)
{
    fprintf(stream,
        "Usage: %s --pattern P --width W --height H --fps F --port N --output FILE [options]\n"
        "\n"
        "Required arguments:\n"
        "  --pattern P           videotestsrc pattern: smpte, ball, snow, zone-plate\n"
        "  --width W             frame width in pixels (16..4096, even)\n"
        "  --height H            frame height in pixels (16..4096, even)\n"
        "  --fps F               frame rate in frames per second (1..120)\n"
        "  --port N              RTP/UDP destination port on 127.0.0.1 (1024..65535)\n"
        "  --output FILE         recording file; extension selects the container:\n"
        "                        .mkv (Matroska) or .ts (MPEG-TS)\n"
        "\n"
        "Optional arguments:\n"
        "  --codec C             network codec: h264 (default) or jpeg\n"
        "  --overlay-position P  top-left, top-center (default) or bottom-right\n"
        "  --team NAMES          team member names shown in the overlay\n"
        "                        (default: \"Nassim Mahnane\")\n"
        "  --duration S          send EOS and stop cleanly after S seconds\n"
        "  --headless            replace the preview window by a fakesink\n"
        "  --help                show this message and exit\n"
        "\n"
        "Example:\n"
        "  %s --pattern smpte --width 800 --height 450 --fps 10 --port 5123 \\\n"
        "     --output artifacts/test-recording.mkv --duration 15 --headless\n",
        program_name, program_name);
}

static gboolean parse_int(const char *option, const char *text, int min, int max, int *result)
{
    char *end = NULL;
    long value;

    if (text == NULL || *text == '\0') {
        fprintf(stderr, "ERROR: option %s requires a numeric value\n", option);
        return FALSE;
    }
    errno = 0;
    value = strtol(text, &end, 10);
    if (errno != 0 || *end != '\0' || value < min || value > max) {
        fprintf(stderr, "ERROR: invalid value '%s' for %s (expected an integer between %d and %d)\n",
                text, option, min, max);
        return FALSE;
    }
    *result = (int) value;
    return TRUE;
}

static gboolean is_in_list(const char *value, const char *const *list)
{
    for (int i = 0; list[i] != NULL; i++)
        if (strcmp(value, list[i]) == 0)
            return TRUE;
    return FALSE;
}

static const char *container_muxer_for(const char *output_path)
{
    const char *extension = strrchr(output_path, '.');

    if (extension == NULL)
        return NULL;
    if (strcmp(extension, ".mkv") == 0)
        return "matroskamux";
    if (strcmp(extension, ".ts") == 0)
        return "mpegtsmux";
    return NULL;
}

/* Returns 0 on success, 1 on invalid arguments, 2 if --help was requested. */
static int parse_arguments(int argc, char **argv, SenderOptions *options)
{
    static const char *const codecs[] = {"h264", "jpeg", NULL};
    static const char *const positions[] = {"top-left", "top-center", "bottom-right", NULL};
    gboolean have_width = FALSE, have_height = FALSE, have_fps = FALSE, have_port = FALSE;

    memset(options, 0, sizeof(*options));
    options->network_codec = "h264";
    options->overlay_position = "top-center";
    options->team_members = "Nassim Mahnane";

    for (int i = 1; i < argc; i++) {
        const char *option = argv[i];
        const char *value = NULL;

        if (strcmp(option, "--help") == 0 || strcmp(option, "-h") == 0)
            return 2;
        if (strcmp(option, "--headless") == 0) {
            options->headless = TRUE;
            continue;
        }
        if (strncmp(option, "--", 2) != 0) {
            fprintf(stderr, "ERROR: unexpected argument '%s'\n", option);
            return 1;
        }
        if (i + 1 >= argc) {
            fprintf(stderr, "ERROR: option %s requires a value\n", option);
            return 1;
        }
        value = argv[++i];

        if (strcmp(option, "--pattern") == 0) {
            options->pattern = value;
        } else if (strcmp(option, "--width") == 0) {
            if (!parse_int(option, value, 16, 4096, &options->width)) return 1;
            have_width = TRUE;
        } else if (strcmp(option, "--height") == 0) {
            if (!parse_int(option, value, 16, 4096, &options->height)) return 1;
            have_height = TRUE;
        } else if (strcmp(option, "--fps") == 0) {
            if (!parse_int(option, value, 1, 120, &options->fps)) return 1;
            have_fps = TRUE;
        } else if (strcmp(option, "--port") == 0) {
            if (!parse_int(option, value, 1024, 65535, &options->port)) return 1;
            have_port = TRUE;
        } else if (strcmp(option, "--output") == 0) {
            options->output_path = value;
        } else if (strcmp(option, "--duration") == 0) {
            if (!parse_int(option, value, 1, INT_MAX, &options->duration_seconds)) return 1;
        } else if (strcmp(option, "--codec") == 0) {
            options->network_codec = value;
        } else if (strcmp(option, "--overlay-position") == 0) {
            options->overlay_position = value;
        } else if (strcmp(option, "--team") == 0) {
            options->team_members = value;
        } else {
            fprintf(stderr, "ERROR: unknown option '%s'\n", option);
            return 1;
        }
    }

    if (options->pattern == NULL || !have_width || !have_height || !have_fps ||
        !have_port || options->output_path == NULL) {
        fprintf(stderr, "ERROR: missing required argument(s):%s%s%s%s%s%s\n",
                options->pattern == NULL ? " --pattern" : "",
                have_width ? "" : " --width",
                have_height ? "" : " --height",
                have_fps ? "" : " --fps",
                have_port ? "" : " --port",
                options->output_path == NULL ? " --output" : "");
        return 1;
    }
    if (!is_in_list(options->pattern, SUPPORTED_PATTERNS)) {
        fprintf(stderr, "ERROR: unsupported pattern '%s' (supported: smpte, ball, snow, zone-plate)\n",
                options->pattern);
        return 1;
    }
    if (options->width % 2 != 0 || options->height % 2 != 0) {
        fprintf(stderr, "ERROR: width and height must be even (required by I420/H.264)\n");
        return 1;
    }
    if (container_muxer_for(options->output_path) == NULL) {
        fprintf(stderr, "ERROR: unsupported output format '%s' (use a .mkv or .ts file)\n",
                options->output_path);
        return 1;
    }
    if (!is_in_list(options->network_codec, codecs)) {
        fprintf(stderr, "ERROR: unsupported codec '%s' (supported: h264, jpeg)\n", options->network_codec);
        return 1;
    }
    if (!is_in_list(options->overlay_position, positions)) {
        fprintf(stderr, "ERROR: unsupported overlay position '%s'\n", options->overlay_position);
        return 1;
    }
    if (strchr(options->team_members, '"') != NULL) {
        fprintf(stderr, "ERROR: --team must not contain double quotes\n");
        return 1;
    }
    return 0;
}

static gchar *build_pipeline_description(const SenderOptions *options)
{
    const char *text_valign = g_str_has_prefix(options->overlay_position, "top") ? "top" : "bottom";
    const char *text_halign = g_str_has_suffix(options->overlay_position, "left") ? "left"
                            : g_str_has_suffix(options->overlay_position, "center") ? "center" : "right";
    /* Elapsed time goes in the opposite vertical half so the two overlays never overlap. */
    const char *time_valign = strcmp(text_valign, "top") == 0 ? "bottom" : "top";
    const char *muxer = container_muxer_for(options->output_path);
    const char *preview_sink = options->headless
        ? "fakesink name=preview_sink sync=true"
        : "autovideosink name=preview_sink sync=true";
    int keyframe_interval = options->fps * 2;
    gchar *network_branch;
    gchar *description;

    if (strcmp(options->network_codec, "h264") == 0)
        network_branch = g_strdup_printf(
            "x264enc name=network_encoder tune=zerolatency speed-preset=ultrafast key-int-max=%d ! "
            "rtph264pay name=rtp_payloader config-interval=1 pt=96 ! "
            "udpsink name=rtp_sink host=127.0.0.1 port=%d sync=false async=false",
            keyframe_interval, options->port);
    else
        network_branch = g_strdup_printf(
            "jpegenc name=network_encoder quality=85 ! "
            "rtpjpegpay name=rtp_payloader pt=26 ! "
            "udpsink name=rtp_sink host=127.0.0.1 port=%d sync=false async=false",
            options->port);

    description = g_strdup_printf(
        "videotestsrc name=source is-live=true pattern=%s ! "
        "video/x-raw,width=%d,height=%d,framerate=%d/1 ! "
        "videoconvert name=source_convert ! "
        "videobalance name=video_balance ! "
        "textoverlay name=team_overlay text=\"%s | %dx%d @ %d fps\" "
        "valignment=%s halignment=%s font-desc=\"Sans 14\" shaded-background=true ! "
        "timeoverlay name=time_overlay valignment=%s halignment=left font-desc=\"Sans 14\" "
        "shaded-background=true ! "
        "videoconvert name=output_convert ! "
        "video/x-raw,format=I420,width=%d,height=%d,framerate=%d/1 ! "
        "tee name=split "
        "split. ! queue name=preview_queue max-size-buffers=5 leaky=downstream ! "
        "videoconvert name=preview_convert ! %s "
        "split. ! queue name=recording_queue ! "
        "x264enc name=recording_encoder tune=zerolatency speed-preset=ultrafast key-int-max=%d ! "
        "h264parse name=recording_parser ! %s name=recording_muxer ! "
        "filesink name=recording_sink location=\"%s\" "
        "split. ! queue name=network_queue ! %s",
        options->pattern,
        options->width, options->height, options->fps,
        options->team_members, options->width, options->height, options->fps,
        text_valign, text_halign,
        time_valign,
        options->width, options->height, options->fps,
        preview_sink,
        keyframe_interval, muxer, options->output_path,
        network_branch);

    g_free(network_branch);
    return description;
}

static void request_eos(SenderContext *context, const char *reason)
{
    if (context->eos_requested)
        return;
    context->eos_requested = TRUE;
    g_print("Sending EOS to the pipeline (%s)\n", reason);
    gst_element_send_event(context->pipeline, gst_event_new_eos());
}

static gboolean on_duration_elapsed(gpointer user_data)
{
    request_eos((SenderContext *) user_data, "duration elapsed");
    return G_SOURCE_REMOVE;
}

static gboolean on_interrupt_signal(gpointer user_data)
{
    request_eos((SenderContext *) user_data, "interrupt signal");
    return G_SOURCE_CONTINUE;
}

static gboolean on_dynamic_property_timer(gpointer user_data)
{
    SenderContext *context = user_data;
    guint count = G_N_ELEMENTS(BRIGHTNESS_VALUES);
    double brightness;

    context->brightness_step = (context->brightness_step + 1) % count;
    brightness = BRIGHTNESS_VALUES[context->brightness_step];
    g_object_set(context->video_balance, "brightness", brightness, NULL);
    g_print("DYNAMIC_PROPERTY element=video_balance property=brightness value=%.2f\n", brightness);
    return G_SOURCE_CONTINUE;
}

static gboolean on_bus_message(GstBus *bus, GstMessage *message, gpointer user_data)
{
    SenderContext *context = user_data;
    (void) bus;

    switch (GST_MESSAGE_TYPE(message)) {
    case GST_MESSAGE_ERROR: {
        GError *error = NULL;
        gchar *debug_info = NULL;

        gst_message_parse_error(message, &error, &debug_info);
        g_printerr("ERROR from element %s: %s\n", GST_OBJECT_NAME(message->src), error->message);
        g_printerr("Debug information: %s\n", debug_info ? debug_info : "none");
        g_clear_error(&error);
        g_free(debug_info);
        context->error_occurred = TRUE;
        g_main_loop_quit(context->main_loop);
        break;
    }
    case GST_MESSAGE_WARNING: {
        GError *warning = NULL;
        gchar *debug_info = NULL;

        gst_message_parse_warning(message, &warning, &debug_info);
        g_printerr("WARNING from element %s: %s\n", GST_OBJECT_NAME(message->src), warning->message);
        g_printerr("Debug information: %s\n", debug_info ? debug_info : "none");
        g_clear_error(&warning);
        g_free(debug_info);
        break;
    }
    case GST_MESSAGE_EOS:
        g_print("EOS received: recording finalized\n");
        context->eos_received = TRUE;
        g_main_loop_quit(context->main_loop);
        break;
    case GST_MESSAGE_STATE_CHANGED:
        if (GST_MESSAGE_SRC(message) == GST_OBJECT(context->pipeline)) {
            GstState old_state, new_state, pending_state;

            gst_message_parse_state_changed(message, &old_state, &new_state, &pending_state);
            g_print("Pipeline state: %s -> %s\n",
                    gst_element_state_get_name(old_state), gst_element_state_get_name(new_state));
            if (new_state == GST_STATE_PLAYING && !context->dot_dumped) {
                /* Written only when GST_DEBUG_DUMP_DOT_DIR is set. */
                GST_DEBUG_BIN_TO_DOT_FILE(GST_BIN(context->pipeline), GST_DEBUG_GRAPH_SHOW_ALL,
                                          "monitor_sender_playing");
                context->dot_dumped = TRUE;
                g_print("Pipeline is PLAYING\n");
            }
        }
        break;
    default:
        break;
    }
    return TRUE;
}

int main(int argc, char **argv)
{
    SenderOptions options;
    SenderContext context = {0};
    GError *parse_error = NULL;
    gchar *description;
    GstBus *bus;
    guint bus_watch_id, sigint_id, sigterm_id, property_timer_id;
    int parse_status;
    int exit_status;

    gst_init(&argc, &argv);

    parse_status = parse_arguments(argc, argv, &options);
    if (parse_status == 2) {
        print_usage(stdout, argv[0]);
        return EXIT_SUCCESS;
    }
    if (parse_status != 0) {
        fprintf(stderr, "Run '%s --help' for usage.\n", argv[0]);
        return EXIT_FAILURE;
    }

    description = build_pipeline_description(&options);
    g_print("Pipeline description:\n%s\n", description);
    context.pipeline = gst_parse_launch(description, &parse_error);
    g_free(description);
    if (context.pipeline == NULL || parse_error != NULL) {
        g_printerr("ERROR: cannot create the pipeline: %s\n",
                   parse_error ? parse_error->message : "unknown error");
        g_clear_error(&parse_error);
        if (context.pipeline)
            gst_object_unref(context.pipeline);
        return EXIT_FAILURE;
    }

    context.video_balance = gst_bin_get_by_name(GST_BIN(context.pipeline), "video_balance");
    if (context.video_balance == NULL) {
        g_printerr("ERROR: element 'video_balance' not found in the pipeline\n");
        gst_object_unref(context.pipeline);
        return EXIT_FAILURE;
    }

    context.main_loop = g_main_loop_new(NULL, FALSE);
    bus = gst_element_get_bus(context.pipeline);
    bus_watch_id = gst_bus_add_watch(bus, on_bus_message, &context);
    gst_object_unref(bus);

    sigint_id = g_unix_signal_add(SIGINT, on_interrupt_signal, &context);
    sigterm_id = g_unix_signal_add(SIGTERM, on_interrupt_signal, &context);
    property_timer_id = g_timeout_add_seconds(DYNAMIC_PROPERTY_PERIOD_SECONDS,
                                              on_dynamic_property_timer, &context);
    if (options.duration_seconds > 0)
        g_timeout_add_seconds(options.duration_seconds, on_duration_elapsed, &context);

    g_print("Starting sender: pattern=%s %dx%d@%dfps codec=%s port=%d output=%s headless=%s duration=%d\n",
            options.pattern, options.width, options.height, options.fps, options.network_codec,
            options.port, options.output_path, options.headless ? "yes" : "no", options.duration_seconds);

    if (gst_element_set_state(context.pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        g_printerr("ERROR: unable to set the pipeline to PLAYING\n");
        context.error_occurred = TRUE;
    } else {
        g_main_loop_run(context.main_loop);
    }

    g_print("Stopping pipeline (state NULL)\n");
    gst_element_set_state(context.pipeline, GST_STATE_NULL);

    g_source_remove(property_timer_id);
    g_source_remove(sigint_id);
    g_source_remove(sigterm_id);
    g_source_remove(bus_watch_id);
    gst_object_unref(context.video_balance);
    gst_object_unref(context.pipeline);
    g_main_loop_unref(context.main_loop);
    gst_deinit();

    exit_status = (context.error_occurred || !context.eos_received) ? EXIT_FAILURE : EXIT_SUCCESS;
    g_print("Sender finished with status %d\n", exit_status);
    return exit_status;
}
