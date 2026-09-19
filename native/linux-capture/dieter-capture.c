#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconversion"
#endif

#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video-event.h>
#include <json-glib/json-glib.h>
#include <math.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <X11/extensions/XTest.h>

#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#define HELPER_VERSION "linux-native-v1"
#define MAX_STREAMS 4
#define MAX_COMMAND_BYTES (16 * 1024)
#define MAX_FRAME_BYTES (16 * 1024 * 1024)
#define PORTAL_TIMEOUT_SECONDS 120

typedef struct {
    gchar *id;
    gchar *name;
    gint x, y, width, height;
    gdouble refresh;
    gboolean primary;
} DisplayInfo;

typedef struct {
    gchar display_id[65];
    gint max_width, max_height, fps, bitrate_kbps;
    gboolean embedded_cursor;
} StreamConfig;

typedef struct PortalState PortalState;
typedef struct CaptureApp CaptureApp;

typedef struct {
    CaptureApp *app;
    guint64 id, frame_id, generation, dropped, last_pts;
    gint64 next_emit_us;
    StreamConfig config;
    gchar profile[16];
    GstElement *pipeline;
    GstElement *encoder;
    GstElement *rate;
    GstAppSink *sink;
    GThread *bus_thread;
    gchar *encoder_name;
    gchar encoder_factory[32];
    gint x, y, source_width, source_height;
    gboolean credit, stopping;
    GMutex lock;
} CaptureStream;

struct PortalState {
    GDBusConnection *bus;
    gchar *session_path;
    gchar *state_path;
    guint32 node_id, devices;
    gint pipewire_fd;
    gint width, height;
};

struct CaptureApp {
    gboolean multiplex, synthetic, allow_input;
    gint event_fd;
    GHashTable *streams;
    GMutex streams_lock, output_lock, event_lock, input_lock;
    PortalState portal;
    Display *xdisplay;
    gboolean xinput_supported;
    gboolean held_keys[256], held_buttons[16];
    gchar *session_type;
};

typedef struct {
    gboolean capabilities, check_control, request_control;
    gboolean multiplex, synthetic, allow_input, embedded_cursor;
    gint event_fd, fps, bitrate_kbps, max_width, max_height;
    gchar *display_id, *profile, *codec, *portal_state;
} Options;

static void diagnostic(const gchar *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
}

static gboolean write_all(gint fd, const guint8 *data, gsize length) {
    gsize offset = 0;
    while (offset < length) {
        ssize_t count = write(fd, data + offset, length - offset);
        if (count > 0) {
            offset += (gsize)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        return FALSE;
    }
    return TRUE;
}

static void put_u32(guint8 *p, guint32 value) {
    value = GUINT32_TO_BE(value);
    memcpy(p, &value, sizeof(value));
}

static void put_u64(guint8 *p, guint64 value) {
    value = GUINT64_TO_BE(value);
    memcpy(p, &value, sizeof(value));
}

static gchar *read_proc_environment(pid_t pid, gsize *length) {
    gchar path[64];
    g_snprintf(path, sizeof(path), "/proc/%ld/environ", (long)pid);
    gchar *raw = NULL;
    if (!g_file_get_contents(path, &raw, length, NULL) || *length > (1U << 20)) {
        g_free(raw);
        return NULL;
    }
    return raw;
}

static const gchar *environment_value(const gchar *raw, gsize length, const gchar *name) {
    gsize wanted = strlen(name);
    for (gsize offset = 0; offset < length;) {
        const gchar *entry = raw + offset;
        gsize available = length - offset;
        gsize entry_length = strnlen(entry, available);
        if (entry_length == available) break;
        if (entry_length > wanted && entry[wanted] == '=' && memcmp(entry, name, wanted) == 0)
            return entry + wanted + 1;
        offset += entry_length + 1;
    }
    return NULL;
}

static void copy_missing_environment(const gchar *raw, gsize length, const gchar *name) {
    if (g_getenv(name) != NULL) return;
    const gchar *value = environment_value(raw, length, name);
    if (value != NULL && *value != '\0') g_setenv(name, value, FALSE);
}

/* A managed daemon may predate the graphical login and therefore have none of
 * the desktop variables. Discover only same-uid processes and copy a bounded,
 * allow-listed session environment. No credentials or arbitrary variables cross. */
static void discover_graphical_environment(void) {
    uid_t uid = getuid();
    if (g_getenv("XDG_RUNTIME_DIR") == NULL) {
        gchar *runtime = g_strdup_printf("/run/user/%lu", (unsigned long)uid);
        if (g_file_test(runtime, G_FILE_TEST_IS_DIR)) g_setenv("XDG_RUNTIME_DIR", runtime, FALSE);
        g_free(runtime);
    }
    if (g_getenv("DBUS_SESSION_BUS_ADDRESS") == NULL && g_getenv("XDG_RUNTIME_DIR") != NULL) {
        gchar *bus = g_strdup_printf("unix:path=%s/bus", g_getenv("XDG_RUNTIME_DIR"));
        g_setenv("DBUS_SESSION_BUS_ADDRESS", bus, FALSE);
        g_free(bus);
    }
    if (g_getenv("DISPLAY") != NULL || g_getenv("WAYLAND_DISPLAY") != NULL) return;

    GDir *proc = g_dir_open("/proc", 0, NULL);
    if (proc == NULL) return;
    const gchar *entry;
    while ((entry = g_dir_read_name(proc)) != NULL) {
        gchar *end = NULL;
        long value = strtol(entry, &end, 10);
        if (value <= 1 || end == NULL || *end != '\0') continue;
        gchar path[64];
        struct stat st;
        g_snprintf(path, sizeof(path), "/proc/%ld", value);
        if (stat(path, &st) != 0 || st.st_uid != uid) continue;
        gsize length = 0;
        gchar *raw = read_proc_environment((pid_t)value, &length);
        if (raw == NULL) continue;
        const gchar *type = environment_value(raw, length, "XDG_SESSION_TYPE");
        const gchar *display = environment_value(raw, length, "DISPLAY");
        const gchar *wayland = environment_value(raw, length, "WAYLAND_DISPLAY");
        if ((type != NULL && (g_str_equal(type, "x11") || g_str_equal(type, "wayland"))) &&
            ((display != NULL && *display != '\0') || (wayland != NULL && *wayland != '\0'))) {
            const gchar *names[] = {"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR",
                                    "DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP",
                                    "XDG_SESSION_ID", "XDG_SEAT", NULL};
            for (gint i = 0; names[i] != NULL; i++) copy_missing_environment(raw, length, names[i]);
            g_free(raw);
            break;
        }
        g_free(raw);
    }
    g_dir_close(proc);
}

static gchar *session_type(void) {
    const gchar *forced = g_getenv("DIETER_LINUX_CAPTURE_BACKEND");
    if (forced != NULL && g_str_equal(forced, "portal")) return g_strdup("wayland");
    if (forced != NULL && g_str_equal(forced, "x11")) return g_strdup("x11");
    const gchar *value = g_getenv("XDG_SESSION_TYPE");
    if (value != NULL && g_str_equal(value, "wayland")) return g_strdup("wayland");
    if (g_getenv("WAYLAND_DISPLAY") != NULL && g_getenv("DISPLAY") == NULL) return g_strdup("wayland");
    if (g_getenv("DISPLAY") != NULL) return g_strdup("x11");
    return g_strdup("none");
}

static void display_info_free(gpointer data) {
    DisplayInfo *display = data;
    if (display == NULL) return;
    g_free(display->id);
    g_free(display->name);
    g_free(display);
}

static GPtrArray *x11_displays(Display **opened) {
    GPtrArray *result = g_ptr_array_new_with_free_func(display_info_free);
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) return result;
    Window root = DefaultRootWindow(display);
    int count = 0;
    XRRMonitorInfo *monitors = XRRGetMonitors(display, root, True, &count);
    for (int i = 0; monitors != NULL && i < count && i < 32; i++) {
        DisplayInfo *item = g_new0(DisplayInfo, 1);
        gchar *atom = XGetAtomName(display, monitors[i].name);
        item->id = g_strdup_printf("x11:%s", atom != NULL ? atom : "monitor");
        item->name = g_strdup(atom != NULL ? atom : "X11 display");
        if (atom != NULL) XFree(atom);
        item->x = monitors[i].x;
        item->y = monitors[i].y;
        item->width = monitors[i].width;
        item->height = monitors[i].height;
        item->primary = monitors[i].primary;
        item->refresh = 60.0;
        g_ptr_array_add(result, item);
    }
    if (monitors != NULL) XRRFreeMonitors(monitors);
    if (result->len == 0) {
        DisplayInfo *item = g_new0(DisplayInfo, 1);
        item->id = g_strdup("x11:primary");
        item->name = g_strdup("X11 display");
        item->width = DisplayWidth(display, DefaultScreen(display));
        item->height = DisplayHeight(display, DefaultScreen(display));
        item->primary = TRUE;
        item->refresh = 60.0;
        g_ptr_array_add(result, item);
    }
    if (opened != NULL) *opened = display;
    else XCloseDisplay(display);
    return result;
}

static gboolean has_element(const gchar *name) {
    GstElementFactory *factory = gst_element_factory_find(name);
    if (factory == NULL) return FALSE;
    gst_object_unref(factory);
    return TRUE;
}

static const gchar *available_encoder(gboolean *hardware) {
    const gchar *hardware_names[] = {"vah264enc", "nvh264enc", "v4l2h264enc", NULL};
    for (gint i = 0; hardware_names[i] != NULL; i++) {
        if (has_element(hardware_names[i])) {
            *hardware = TRUE;
            return hardware_names[i];
        }
    }
    *hardware = FALSE;
    if (has_element("x264enc")) return "x264enc";
    if (has_element("openh264enc")) return "openh264enc";
    return NULL;
}

static guint32 portal_version(const gchar *interface) {
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (bus == NULL) {
        g_clear_error(&error);
        return 0;
    }
    GVariant *reply = g_dbus_connection_call_sync(bus, "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop", "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", interface, "version"), G_VARIANT_TYPE("(v)"),
        G_DBUS_CALL_FLAGS_NONE, 3000, NULL, &error);
    guint32 version = 0;
    if (reply != NULL) {
        GVariant *boxed = NULL;
        g_variant_get(reply, "(@v)", &boxed);
        GVariant *inner = g_variant_get_variant(boxed);
        version = g_variant_get_uint32(inner);
        g_variant_unref(inner);
        g_variant_unref(boxed);
        g_variant_unref(reply);
    }
    g_clear_error(&error);
    g_object_unref(bus);
    return version;
}

static void add_display_json(JsonBuilder *builder, const DisplayInfo *display) {
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "id"); json_builder_add_string_value(builder, display->id);
    json_builder_set_member_name(builder, "name"); json_builder_add_string_value(builder, display->name);
    json_builder_set_member_name(builder, "logical_width"); json_builder_add_int_value(builder, display->width);
    json_builder_set_member_name(builder, "logical_height"); json_builder_add_int_value(builder, display->height);
    json_builder_set_member_name(builder, "physical_width"); json_builder_add_int_value(builder, display->width);
    json_builder_set_member_name(builder, "physical_height"); json_builder_add_int_value(builder, display->height);
    json_builder_set_member_name(builder, "scale"); json_builder_add_double_value(builder, 1.0);
    json_builder_set_member_name(builder, "rotation"); json_builder_add_int_value(builder, 0);
    json_builder_set_member_name(builder, "primary"); json_builder_add_boolean_value(builder, display->primary);
    json_builder_set_member_name(builder, "origin_x"); json_builder_add_int_value(builder, display->x);
    json_builder_set_member_name(builder, "origin_y"); json_builder_add_int_value(builder, display->y);
    json_builder_set_member_name(builder, "refresh_rate"); json_builder_add_double_value(builder, display->refresh);
    json_builder_end_object(builder);
}

static gboolean write_json_node(JsonNode *root, gint fd) {
    JsonGenerator *generator = json_generator_new();
    json_generator_set_root(generator, root);
    gsize length = 0;
    gchar *data = json_generator_to_data(generator, &length);
    gboolean ok = write_all(fd, (const guint8 *)data, length);
    g_free(data);
    g_object_unref(generator);
    return ok;
}

static gboolean portal_state_exists(const gchar *path) {
    if (path == NULL || *path == '\0') return FALSE;
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() && (st.st_mode & 077) == 0;
}

static int print_capabilities(const Options *options) {
    gchar *type = session_type();
    gboolean hardware = FALSE;
    const gchar *encoder = available_encoder(&hardware);
    gboolean pipeline = has_element("h264parse") && has_element("appsink") && encoder != NULL;
    GPtrArray *displays = NULL;
    guint32 screencast_version = 0, remote_version = 0;
    gboolean graphical = FALSE, capture = FALSE, control = FALSE, consent = FALSE;

    if (options->synthetic) {
        displays = g_ptr_array_new_with_free_func(display_info_free);
        DisplayInfo *item = g_new0(DisplayInfo, 1);
        item->id = g_strdup("synthetic"); item->name = g_strdup("Synthetic display");
        item->width = 1920; item->height = 1080; item->refresh = 60; item->primary = TRUE;
        g_ptr_array_add(displays, item);
        graphical = capture = control = TRUE;
    } else if (g_str_equal(type, "x11")) {
        displays = x11_displays(NULL);
        graphical = displays->len > 0;
        capture = graphical && has_element("ximagesrc");
        Display *probe = NULL;
        GPtrArray *unused = x11_displays(&probe);
        if (probe != NULL) {
            int event_base = 0, error_base = 0, major = 0, minor = 0;
            control = XTestQueryExtension(probe, &event_base, &error_base, &major, &minor);
            XCloseDisplay(probe);
        }
        g_ptr_array_unref(unused);
    } else if (g_str_equal(type, "wayland")) {
        screencast_version = portal_version("org.freedesktop.portal.ScreenCast");
        remote_version = portal_version("org.freedesktop.portal.RemoteDesktop");
        graphical = screencast_version > 0;
        capture = graphical && has_element("pipewiresrc");
        control = remote_version > 0;
        consent = !portal_state_exists(options->portal_state);
        displays = g_ptr_array_new_with_free_func(display_info_free);
        if (capture) {
            DisplayInfo *item = g_new0(DisplayInfo, 1);
            item->id = g_strdup("portal"); item->name = g_strdup("Desktop portal selection");
            item->width = 1920; item->height = 1080; item->refresh = 60; item->primary = TRUE;
            g_ptr_array_add(displays, item);
        }
    } else {
        displays = g_ptr_array_new_with_free_func(display_info_free);
    }

    const gchar *reason = "";
    const gchar *code = "ready";
    if (!graphical) { reason = "No supported graphical login session is active"; code = "no_graphical_session"; }
    else if (!capture) { reason = "The active Linux session has no usable X11 or portal/PipeWire capture backend"; code = "capture_backend_unavailable"; }
    else if (!pipeline) { reason = "GStreamer H.264 parser, appsink, or encoder plugins are unavailable"; code = "encoder_unavailable"; }

    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
#define BOOL_MEMBER(name, value) do { json_builder_set_member_name(builder, name); json_builder_add_boolean_value(builder, value); } while (0)
#define STR_MEMBER(name, value) do { json_builder_set_member_name(builder, name); json_builder_add_string_value(builder, value); } while (0)
#define INT_MEMBER(name, value) do { json_builder_set_member_name(builder, name); json_builder_add_int_value(builder, value); } while (0)
    STR_MEMBER("platform", "linux");
    STR_MEMBER("helper_version", HELPER_VERSION);
    BOOL_MEMBER("graphical_session_active", graphical);
    STR_MEMBER("capture_permission", capture ? (consent ? "not_requested" : "granted") : "denied");
    STR_MEMBER("control_permission", control ? (consent ? "not_requested" : "granted") : "unsupported");
    json_builder_set_member_name(builder, "displays"); json_builder_begin_array(builder);
    for (guint i = 0; i < displays->len; i++) add_display_json(builder, g_ptr_array_index(displays, i));
    json_builder_end_array(builder);
    json_builder_set_member_name(builder, "codecs"); json_builder_begin_array(builder);
    if (pipeline) json_builder_add_string_value(builder, "H264");
    json_builder_end_array(builder);
    /* This legacy field means a production encoder is usable to old clients.
     * The exact hardware/software identity remains in encoder and the additive
     * software_encoder_available diagnostic until the public schema grows. */
    BOOL_MEMBER("hardware_encoder_available", pipeline);
    BOOL_MEMBER("software_encoder_available", encoder != NULL && !hardware);
    BOOL_MEMBER("control_supported", control);
    BOOL_MEMBER("clipboard_supported", FALSE);
    BOOL_MEMBER("binary_clipboard_supported", FALSE);
    BOOL_MEMBER("audio_supported", FALSE);
    BOOL_MEMBER("file_transfer_supported", FALSE);
    BOOL_MEMBER("adaptive_supported", TRUE);
    /* The initial Linux backend uses compositor/XImage embedded cursors. */
    BOOL_MEMBER("cursor_supported", FALSE);
    INT_MEMBER("input_protocol_version", 3);
    INT_MEMBER("max_fps", hardware ? 120 : 30);
    STR_MEMBER("encoder", encoder != NULL ? encoder : "");
    BOOL_MEMBER("display_mode_switching_supported", FALSE);
    STR_MEMBER("capture_backend", options->synthetic ? "synthetic" : g_str_equal(type, "wayland") ? "portal-pipewire" : g_str_equal(type, "x11") ? "x11-gstreamer" : "none");
    STR_MEMBER("graphical_session_id", g_getenv("XDG_SESSION_ID") != NULL ? g_getenv("XDG_SESSION_ID") : "");
    STR_MEMBER("graphical_session_type", type);
    STR_MEMBER("desktop", g_getenv("XDG_CURRENT_DESKTOP") != NULL ? g_getenv("XDG_CURRENT_DESKTOP") : "");
    STR_MEMBER("seat", g_getenv("XDG_SEAT") != NULL ? g_getenv("XDG_SEAT") : "");
    STR_MEMBER("source_selection_mode", g_str_equal(type, "wayland") ? "authorized_or_interactive" : "enumerated");
    BOOL_MEMBER("local_consent_required", consent);
    STR_MEMBER("readiness_code", code);
    INT_MEMBER("portal_screencast_version", screencast_version);
    INT_MEMBER("portal_remote_desktop_version", remote_version);
    BOOL_MEMBER("pointer_input_supported", control);
    BOOL_MEMBER("button_input_supported", control);
    BOOL_MEMBER("scroll_input_supported", control);
    BOOL_MEMBER("keyboard_input_supported", control);
    BOOL_MEMBER("text_input_supported", FALSE);
    BOOL_MEMBER("touch_input_supported", FALSE);
    BOOL_MEMBER("text_clipboard_supported", FALSE);
    BOOL_MEMBER("image_clipboard_supported", FALSE);
    BOOL_MEMBER("file_clipboard_supported", FALSE);
    BOOL_MEMBER("live_reconfiguration_supported", TRUE);
    if (*reason != '\0') STR_MEMBER("unavailable_reason", reason);
    json_builder_end_object(builder);
    JsonNode *root = json_builder_get_root(builder);
    gboolean ok = write_json_node(root, STDOUT_FILENO);
    json_node_free(root);
    g_object_unref(builder);
    g_ptr_array_unref(displays);
    g_free(type);
    return ok ? 0 : 1;
#undef BOOL_MEMBER
#undef STR_MEMBER
#undef INT_MEMBER
}

typedef struct {
    GMainLoop *loop;
    guint32 response;
    GVariant *results;
} PortalReply;

static void portal_response(GDBusConnection *connection, const gchar *sender, const gchar *path,
                            const gchar *interface, const gchar *signal, GVariant *parameters,
                            gpointer data) {
    (void)connection; (void)sender; (void)path; (void)interface; (void)signal;
    PortalReply *reply = data;
    GVariant *results = NULL;
    g_variant_get(parameters, "(u@a{sv})", &reply->response, &results);
    reply->results = results;
    g_main_loop_quit(reply->loop);
}

static gboolean portal_timeout(gpointer data) {
    PortalReply *reply = data;
    reply->response = G_MAXUINT32;
    g_main_loop_quit(reply->loop);
    return G_SOURCE_REMOVE;
}

static gchar *portal_sender_component(GDBusConnection *bus) {
    const gchar *unique = g_dbus_connection_get_unique_name(bus);
    gchar *result = g_strdup(unique != NULL && unique[0] == ':' ? unique + 1 : unique);
    for (gchar *p = result; p != NULL && *p != '\0'; p++) if (*p == '.') *p = '_';
    return result;
}

static GVariant *portal_request(PortalState *portal, const gchar *interface, const gchar *method,
                                GVariant *parameters, const gchar *token, GError **error) {
    gchar *sender = portal_sender_component(portal->bus);
    gchar *path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
    g_free(sender);
    PortalReply reply = {.loop = g_main_loop_new(NULL, FALSE), .response = G_MAXUINT32, .results = NULL};
    guint subscription = g_dbus_connection_signal_subscribe(portal->bus, "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request", "Response", path, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        portal_response, &reply, NULL);
    GVariant *call = g_dbus_connection_call_sync(portal->bus, "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop", interface, method, parameters, G_VARIANT_TYPE("(o)"),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, error);
    if (call == NULL) {
        g_dbus_connection_signal_unsubscribe(portal->bus, subscription);
        g_main_loop_unref(reply.loop);
        g_free(path);
        return NULL;
    }
    g_variant_unref(call);
    guint timeout = g_timeout_add_seconds(PORTAL_TIMEOUT_SECONDS, portal_timeout, &reply);
    g_main_loop_run(reply.loop);
    if (timeout != 0 && reply.response != G_MAXUINT32) g_source_remove(timeout);
    g_dbus_connection_signal_unsubscribe(portal->bus, subscription);
    g_main_loop_unref(reply.loop);
    g_free(path);
    if (reply.response == G_MAXUINT32) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "desktop portal authorization timed out");
    } else if (reply.response != 0) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                    "desktop portal request was denied or cancelled (response %u)", reply.response);
    }
    if (error != NULL && *error != NULL) {
        if (reply.results != NULL) g_variant_unref(reply.results);
        return NULL;
    }
    return reply.results;
}

static void variant_option(GVariantBuilder *builder, const gchar *name, GVariant *value) {
    g_variant_builder_add(builder, "{sv}", name, value);
}

static gchar *load_restore_token(const gchar *path) {
    if (!portal_state_exists(path)) return NULL;
    gchar *token = NULL;
    if (!g_file_get_contents(path, &token, NULL, NULL)) return NULL;
    g_strstrip(token);
    if (*token == '\0' || strlen(token) > 4096) { g_free(token); return NULL; }
    return token;
}

static gchar *acquire_store_lock(const gchar *state_path) {
    gchar *screen_directory = g_path_get_dirname(state_path);
    gchar *root = g_path_get_dirname(screen_directory);
    gchar *lock = g_build_filename(root, ".write-lock", NULL);
    g_free(root);
    g_free(screen_directory);
    gint64 deadline = g_get_monotonic_time() + 10 * G_TIME_SPAN_SECOND;
    while (mkdir(lock, 0700) != 0) {
        if (errno != EEXIST || g_get_monotonic_time() >= deadline) {
            g_free(lock);
            return NULL;
        }
        g_usleep(5000);
    }
    gchar *owner = g_build_filename(lock, "owner", NULL);
    gint fd = open(owner, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    gchar *pid = g_strdup_printf("%ld", (long)getpid());
    gboolean ok = fd >= 0 && write_all(fd, (const guint8 *)pid, strlen(pid));
    if (fd >= 0 && close(fd) != 0) ok = FALSE;
    g_free(pid);
    g_free(owner);
    if (!ok) {
        (void)rmdir(lock);
        g_free(lock);
        return NULL;
    }
    return lock;
}

static void release_store_lock(gchar *lock) {
    if (lock == NULL) return;
    gchar *owner = g_build_filename(lock, "owner", NULL);
    (void)unlink(owner);
    (void)rmdir(lock);
    g_free(owner);
    g_free(lock);
}

static void save_restore_token(const gchar *path, const gchar *token) {
    if (path == NULL || *path == '\0' || token == NULL || *token == '\0' || strlen(token) > 4096) return;
    gchar *lock = acquire_store_lock(path);
    if (lock == NULL) return;
    gchar *directory = g_path_get_dirname(path);
    if (g_mkdir_with_parents(directory, 0700) != 0) {
        g_free(directory);
        release_store_lock(lock);
        return;
    }
    chmod(directory, 0700);
    gchar *temporary = g_strdup_printf("%s.tmp.%ld", path, (long)getpid());
    gint fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd >= 0) {
        gboolean ok = write_all(fd, (const guint8 *)token, strlen(token));
        if (ok) ok = fsync(fd) == 0;
        if (close(fd) != 0) ok = FALSE;
        if (ok && rename(temporary, path) == 0) {
            gint directory_fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (directory_fd >= 0) { (void)fsync(directory_fd); (void)close(directory_fd); }
        }
        else (void)unlink(temporary);
    }
    g_free(temporary);
    g_free(directory);
    release_store_lock(lock);
}

static void portal_close(PortalState *portal);

static gboolean portal_start(CaptureApp *app, GError **error) {
    PortalState *portal = &app->portal;
    if (portal->session_path != NULL) return TRUE;
    portal->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, error);
    if (portal->bus == NULL) return FALSE;
    const gchar *owner = app->allow_input ? "org.freedesktop.portal.RemoteDesktop" : "org.freedesktop.portal.ScreenCast";
    gchar *nonce = g_strdup_printf("dieter%ld%u", (long)getpid(), g_random_int());

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    variant_option(&options, "handle_token", g_variant_new_string(nonce));
    gchar *session_token = g_strdup_printf("session%s", nonce);
    variant_option(&options, "session_handle_token", g_variant_new_string(session_token));
    GVariant *results = portal_request(portal, owner, "CreateSession",
        g_variant_new("(@a{sv})", g_variant_builder_end(&options)), nonce, error);
    if (results == NULL) goto failed;
    const gchar *session_path = NULL;
    if (!g_variant_lookup(results, "session_handle", "&o", &session_path) || session_path == NULL) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "portal did not return a session handle");
        g_variant_unref(results);
        goto failed;
    }
    portal->session_path = g_strdup(session_path);
    g_variant_unref(results);

    if (app->allow_input) {
        gchar *token = g_strdup_printf("devices%s", nonce);
        g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
        variant_option(&options, "handle_token", g_variant_new_string(token));
        variant_option(&options, "types", g_variant_new_uint32(3));
        results = portal_request(portal, "org.freedesktop.portal.RemoteDesktop", "SelectDevices",
            g_variant_new("(o@a{sv})", portal->session_path, g_variant_builder_end(&options)), token, error);
        g_free(token);
        if (results == NULL) goto failed;
        g_variant_unref(results);
    }

    gchar *token = g_strdup_printf("sources%s", nonce);
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    variant_option(&options, "handle_token", g_variant_new_string(token));
    variant_option(&options, "types", g_variant_new_uint32(1));
    variant_option(&options, "multiple", g_variant_new_boolean(FALSE));
    variant_option(&options, "cursor_mode", g_variant_new_uint32(2));
    variant_option(&options, "persist_mode", g_variant_new_uint32(2));
    gchar *restore = load_restore_token(portal->state_path);
    if (restore != NULL) variant_option(&options, "restore_token", g_variant_new_string(restore));
    results = portal_request(portal, "org.freedesktop.portal.ScreenCast", "SelectSources",
        g_variant_new("(o@a{sv})", portal->session_path, g_variant_builder_end(&options)), token, error);
    g_free(token); g_free(restore);
    if (results == NULL) goto failed;
    g_variant_unref(results);

    token = g_strdup_printf("start%s", nonce);
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    variant_option(&options, "handle_token", g_variant_new_string(token));
    results = portal_request(portal, owner, "Start",
        g_variant_new("(os@a{sv})", portal->session_path, "", g_variant_builder_end(&options)), token, error);
    g_free(token);
    if (results == NULL) goto failed;
    GVariant *streams = g_variant_lookup_value(results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
    if (streams == NULL || g_variant_n_children(streams) == 0) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "portal returned no screen stream");
        if (streams != NULL) g_variant_unref(streams);
        g_variant_unref(results);
        goto failed;
    }
    GVariant *entry = g_variant_get_child_value(streams, 0);
    GVariant *properties = NULL;
    g_variant_get(entry, "(u@a{sv})", &portal->node_id, &properties);
    GVariant *size = g_variant_lookup_value(properties, "size", G_VARIANT_TYPE("(ii)"));
    if (size != NULL) {
        g_variant_get(size, "(ii)", &portal->width, &portal->height);
        g_variant_unref(size);
    }
    g_variant_unref(properties); g_variant_unref(entry); g_variant_unref(streams);
    g_variant_lookup(results, "devices", "u", &portal->devices);
    if (app->allow_input && (portal->devices & 3U) != 3U) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
            "desktop portal did not grant both pointer and keyboard control");
        g_variant_unref(results);
        goto failed;
    }
    const gchar *new_restore = NULL;
    if (g_variant_lookup(results, "restore_token", "&s", &new_restore)) save_restore_token(portal->state_path, new_restore);
    g_variant_unref(results);

    GUnixFDList *fds = NULL;
    GVariantBuilder empty;
    g_variant_builder_init(&empty, G_VARIANT_TYPE_VARDICT);
    GVariant *remote = g_dbus_connection_call_with_unix_fd_list_sync(portal->bus,
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast", "OpenPipeWireRemote",
        g_variant_new("(o@a{sv})", portal->session_path, g_variant_builder_end(&empty)),
        G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, &fds, NULL, error);
    if (remote == NULL) goto failed;
    if (fds == NULL) {
        g_variant_unref(remote);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "portal returned no PipeWire file descriptor");
        goto failed;
    }
    gint handle = -1;
    g_variant_get(remote, "(h)", &handle);
    portal->pipewire_fd = g_unix_fd_list_get(fds, handle, error);
    g_variant_unref(remote); g_object_unref(fds);
    if (portal->pipewire_fd < 0) goto failed;
    g_free(nonce); g_free(session_token);
    return TRUE;

failed:
    portal_close(portal);
    g_free(nonce); g_free(session_token);
    return FALSE;
}

static void portal_close(PortalState *portal) {
    if (portal->bus != NULL && portal->session_path != NULL) {
        GError *error = NULL;
        GVariant *reply = g_dbus_connection_call_sync(portal->bus, "org.freedesktop.portal.Desktop",
            portal->session_path, "org.freedesktop.portal.Session", "Close", NULL, NULL,
            G_DBUS_CALL_FLAGS_NONE, 3000, NULL, &error);
        if (reply != NULL) g_variant_unref(reply);
        g_clear_error(&error);
    }
    if (portal->pipewire_fd >= 0) close(portal->pipewire_fd);
    g_clear_pointer(&portal->session_path, g_free);
    g_clear_object(&portal->bus);
    portal->pipewire_fd = -1;
}

static void emit_event(CaptureApp *app, guint64 stream_id, guint64 ack, const gchar *error,
                       CaptureStream *stream) {
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "version"); json_builder_add_int_value(builder, 2);
    json_builder_set_member_name(builder, "stream_id"); json_builder_add_int_value(builder, (gint64)stream_id);
    json_builder_set_member_name(builder, "ack"); json_builder_add_int_value(builder, (gint64)ack);
    if (error != NULL) {
        json_builder_set_member_name(builder, "error"); json_builder_add_string_value(builder, error);
    }
    if (stream != NULL) {
        json_builder_set_member_name(builder, "state"); json_builder_begin_object(builder);
        json_builder_set_member_name(builder, "width"); json_builder_add_int_value(builder, stream->config.max_width);
        json_builder_set_member_name(builder, "height"); json_builder_add_int_value(builder, stream->config.max_height);
        json_builder_set_member_name(builder, "fps"); json_builder_add_int_value(builder, stream->config.fps);
        json_builder_set_member_name(builder, "bitrate_kbps"); json_builder_add_int_value(builder, stream->config.bitrate_kbps);
        json_builder_set_member_name(builder, "display_id"); json_builder_add_string_value(builder, stream->config.display_id);
        json_builder_set_member_name(builder, "display_generation"); json_builder_add_int_value(builder, (gint64)stream->generation);
        json_builder_set_member_name(builder, "encoder"); json_builder_add_string_value(builder, stream->encoder_name != NULL ? stream->encoder_name : "GStreamer H.264");
        json_builder_set_member_name(builder, "embedded_cursor"); json_builder_add_boolean_value(builder, stream->config.embedded_cursor);
        json_builder_set_member_name(builder, "encoder_configuration"); json_builder_add_string_value(builder, stream->encoder_name != NULL ? stream->encoder_name : "GStreamer H.264");
        json_builder_end_object(builder);
    }
    json_builder_end_object(builder);
    JsonNode *root = json_builder_get_root(builder);
    JsonGenerator *generator = json_generator_new();
    json_generator_set_root(generator, root);
    gsize length = 0;
    gchar *data = json_generator_to_data(generator, &length);
    g_mutex_lock(&app->event_lock);
    gboolean ok = write_all(app->event_fd, (const guint8 *)data, length) && write_all(app->event_fd, (const guint8 *)"\n", 1);
    g_mutex_unlock(&app->event_lock);
    if (!ok) raise(SIGTERM);
    g_free(data); g_object_unref(generator); json_node_free(root); g_object_unref(builder);
}

static gboolean selected_x11_geometry(CaptureStream *stream, GError **error) {
    GPtrArray *displays = x11_displays(NULL);
    DisplayInfo *selected = NULL;
    for (guint i = 0; i < displays->len; i++) {
        DisplayInfo *candidate = g_ptr_array_index(displays, i);
        if (g_str_equal(stream->config.display_id, candidate->id) ||
            ((g_str_equal(stream->config.display_id, "primary") || stream->config.display_id[0] == '\0') && candidate->primary)) {
            selected = candidate;
            break;
        }
    }
    if (selected == NULL && displays->len > 0 &&
        (g_str_equal(stream->config.display_id, "primary") || stream->config.display_id[0] == '\0'))
        selected = g_ptr_array_index(displays, 0);
    if (selected == NULL) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "selected X11 display %s is unavailable", stream->config.display_id);
        g_ptr_array_unref(displays);
        return FALSE;
    }
    stream->x = selected->x; stream->y = selected->y;
    stream->source_width = selected->width; stream->source_height = selected->height;
    g_ptr_array_unref(displays);
    return TRUE;
}

static gchar *encoder_description(const gchar *name) {
    if (g_str_equal(name, "vah264enc")) return g_strdup("GStreamer VA-API H.264");
    if (g_str_equal(name, "nvh264enc")) return g_strdup("GStreamer NVENC H.264");
    if (g_str_equal(name, "v4l2h264enc")) return g_strdup("GStreamer V4L2 H.264");
    if (g_str_equal(name, "x264enc")) return g_strdup("GStreamer x264 software H.264");
    return g_strdup("GStreamer OpenH264 software H.264");
}

static gchar *encoder_pipeline(const gchar *name, const CaptureStream *stream) {
    gint key_interval = MAX(1, MIN(1024, stream->config.fps * 2));
    const gchar *profile = g_str_equal(stream->profile, "baseline") ? "constrained-baseline" : "high";
    if (g_str_equal(name, "openh264enc")) {
        return g_strdup_printf("openh264enc name=dieter_encoder bitrate=%d rate-control=bitrate "
            "usage-type=screen complexity=low enable-frame-skip=true gop-size=%d ! "
            "video/x-h264,profile=constrained-baseline", stream->config.bitrate_kbps * 1000, key_interval);
    }
    if (g_str_equal(name, "x264enc")) {
        return g_strdup_printf("x264enc name=dieter_encoder tune=zerolatency speed-preset=ultrafast "
            "bitrate=%d key-int-max=%d byte-stream=true aud=false bframes=0 ! video/x-h264,profile=%s",
            stream->config.bitrate_kbps, key_interval, profile);
    }
    if (g_str_equal(name, "vah264enc")) {
        return g_strdup_printf("vah264enc name=dieter_encoder bitrate=%d rate-control=cbr target-usage=7 "
            "key-int-max=%d b-frames=0 aud=false ! video/x-h264,profile=%s",
            stream->config.bitrate_kbps, key_interval, profile);
    }
    if (g_str_equal(name, "nvh264enc")) {
        return g_strdup_printf("nvh264enc name=dieter_encoder bitrate=%d gop-size=%d bframes=0 zerolatency=true ! "
            "video/x-h264,profile=%s", stream->config.bitrate_kbps, key_interval, profile);
    }
    return g_strdup("v4l2h264enc name=dieter_encoder ! video/x-h264,profile=high");
}

static GstFlowReturn new_sample(GstAppSink *sink, gpointer data) {
    CaptureStream *stream = data;
    const gchar *stop_file = g_getenv("DIETER_TEST_CAPTURE_STOP_FILE");
    if (stream->app->synthetic && stop_file != NULL && access(stop_file, F_OK) == 0) {
        (void)unlink(stop_file);
        raise(SIGTERM);
        return GST_FLOW_ERROR;
    }
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (sample == NULL) return GST_FLOW_EOS;
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (buffer == NULL || !gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return GST_FLOW_ERROR;
    }
    g_mutex_lock(&stream->lock);
    gint64 now_us = g_get_monotonic_time();
    gint64 minimum_interval = G_USEC_PER_SEC / MAX(1, stream->config.fps);
    if (!stream->credit || stream->stopping || map.size == 0 || map.size > MAX_FRAME_BYTES ||
        (stream->next_emit_us != 0 && now_us < stream->next_emit_us)) {
        stream->dropped++;
        g_mutex_unlock(&stream->lock);
        gst_buffer_unmap(buffer, &map);
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }
    stream->credit = FALSE;
    if (stream->next_emit_us == 0 || stream->next_emit_us < now_us-minimum_interval)
        stream->next_emit_us = now_us + minimum_interval;
    else
        stream->next_emit_us += minimum_interval;
    guint64 frame_id = ++stream->frame_id;
    guint64 generation = stream->generation;
    guint64 dropped = stream->dropped;
    gint width = stream->config.max_width, height = stream->config.max_height;
    stream->last_pts += GST_SECOND / (guint64)MAX(1, stream->config.fps);
    guint64 pts = stream->last_pts;
    g_mutex_unlock(&stream->lock);

    guint8 header[64] = {0};
    const guint8 *payload = map.data;
    gsize payload_size = map.size;
    /* AUD is redundant once the appsink preserves access-unit boundaries and
     * older Dieter viewers expect parameter sets at the first Annex-B offset. */
    if (payload_size >= 6 && payload[0] == 0 && payload[1] == 0 &&
        ((payload[2] == 1 && (payload[3] & 0x1f) == 9) ||
         (payload[2] == 0 && payload[3] == 1 && (payload[4] & 0x1f) == 9))) {
        gsize offset = payload[2] == 1 ? 4 : 5;
        while (offset + 4 < payload_size) {
            if (payload[offset] == 0 && payload[offset + 1] == 0 &&
                (payload[offset + 2] == 1 || (payload[offset + 2] == 0 && payload[offset + 3] == 1))) break;
            offset++;
        }
        if (offset + 4 < payload_size) { payload += offset; payload_size -= offset; }
    }
    put_u32(header, (guint32)payload_size);
    guint32 flags = GST_BUFFER_FLAG_IS_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT) ? 0U : 1U;
    put_u32(header + 4, flags);
    put_u64(header + 8, frame_id);
    put_u64(header + 16, generation);
    put_u64(header + 24, pts);
    put_u32(header + 48, (guint32)width);
    put_u32(header + 52, (guint32)height);
    put_u64(header + 56, dropped);

    CaptureApp *app = stream->app;
    g_mutex_lock(&app->output_lock);
    gboolean ok = TRUE;
    if (app->multiplex) {
        guint8 stream_id[8]; put_u64(stream_id, stream->id);
        ok = write_all(STDOUT_FILENO, stream_id, sizeof(stream_id));
    }
    ok = ok && write_all(STDOUT_FILENO, header, sizeof(header)) && write_all(STDOUT_FILENO, payload, payload_size);
    g_mutex_unlock(&app->output_lock);
    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);
    if (!ok) return GST_FLOW_ERROR;
    return GST_FLOW_OK;
}

static gpointer watch_bus(gpointer data) {
    CaptureStream *stream = data;
    GstBus *bus = gst_element_get_bus(stream->pipeline);
    for (;;) {
        GstMessage *message = gst_bus_timed_pop_filtered(bus, 50 * GST_MSECOND,
            GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
        g_mutex_lock(&stream->lock);
        gboolean stopping = stream->stopping;
        g_mutex_unlock(&stream->lock);
        if (stopping) { if (message != NULL) gst_message_unref(message); break; }
        if (message == NULL) continue;
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
            GError *error = NULL; gchar *debug = NULL;
            gst_message_parse_error(message, &error, &debug);
            emit_event(stream->app, stream->id, 0, error != NULL ? error->message : "GStreamer capture failed", NULL);
            g_clear_error(&error); g_free(debug);
        } else {
            emit_event(stream->app, stream->id, 0, "GStreamer capture ended", NULL);
        }
        gst_message_unref(message);
        break;
    }
    gst_object_unref(bus);
    return NULL;
}

static void stop_pipeline(CaptureStream *stream) {
    g_mutex_lock(&stream->lock);
    stream->stopping = TRUE;
    g_mutex_unlock(&stream->lock);
    if (stream->pipeline != NULL) gst_element_set_state(stream->pipeline, GST_STATE_NULL);
    if (stream->bus_thread != NULL) {
        g_thread_join(stream->bus_thread);
        stream->bus_thread = NULL;
    }
    if (stream->pipeline != NULL) gst_object_unref(stream->pipeline);
    stream->pipeline = NULL; stream->encoder = NULL; stream->rate = NULL; stream->sink = NULL;
    g_clear_pointer(&stream->encoder_name, g_free);
}

static gboolean start_pipeline(CaptureStream *stream, GError **error) {
    CaptureApp *app = stream->app;
    gchar *source = NULL;
    if (app->synthetic) {
        const gchar *delay_value = g_getenv("DIETER_TEST_CAPTURE_START_DELAY_MS");
        if (delay_value != NULL) {
            gchar *end = NULL;
            gint64 delay_ms = g_ascii_strtoll(delay_value, &end, 10);
            if (end != delay_value && *end == '\0' && delay_ms > 0 && delay_ms <= 10000)
                g_usleep((gulong)delay_ms * 1000UL);
        }
        source = g_strdup("videotestsrc is-live=true pattern=ball");
        stream->source_width = 1920; stream->source_height = 1080;
    } else if (g_str_equal(app->session_type, "wayland")) {
        if (!portal_start(app, error)) return FALSE;
        gint fd = dup(app->portal.pipewire_fd);
        if (fd < 0) { g_set_error(error, G_IO_ERROR, g_io_error_from_errno(errno), "duplicate PipeWire fd: %s", g_strerror(errno)); return FALSE; }
        source = g_strdup_printf("pipewiresrc fd=%d path=%u do-timestamp=true", fd, app->portal.node_id);
        stream->source_width = app->portal.width > 0 ? app->portal.width : stream->config.max_width;
        stream->source_height = app->portal.height > 0 ? app->portal.height : stream->config.max_height;
    } else {
        if (!selected_x11_geometry(stream, error)) return FALSE;
        source = g_strdup_printf("ximagesrc use-damage=true show-pointer=%s startx=%d starty=%d endx=%d endy=%d",
            stream->config.embedded_cursor ? "true" : "false", stream->x, stream->y,
            stream->x + stream->source_width - 1, stream->y + stream->source_height - 1);
    }

    const gchar *production[] = {"vah264enc", "nvh264enc", "v4l2h264enc", "x264enc", "openh264enc", NULL};
    const gchar *fixture[] = {"x264enc", "openh264enc", "vah264enc", "nvh264enc", "v4l2h264enc", NULL};
    const gchar **candidates = app->synthetic ? fixture : production;
    gboolean started = FALSE;
    for (gint i = 0; candidates[i] != NULL && !started; i++) {
        if (!has_element(candidates[i])) continue;
        gchar *encoder = encoder_pipeline(candidates[i], stream);
        gchar *pipeline_text = g_strdup_printf(
            "%s ! queue max-size-buffers=1 leaky=downstream ! videoconvert ! videoscale ! videorate name=dieter_rate drop-only=true max-rate=%d ! "
            "video/x-raw,format=NV12,width=%d,height=%d,framerate=%d/1 ! %s ! "
            "h264parse config-interval=-1 disable-passthrough=true ! video/x-h264,stream-format=byte-stream,alignment=au ! "
            "appsink name=dieter_sink emit-signals=true sync=false max-buffers=1 drop=true",
            source, stream->config.fps, stream->config.max_width, stream->config.max_height, stream->config.fps, encoder);
        GError *pipeline_error = NULL;
        GstElement *pipeline = gst_parse_launch(pipeline_text, &pipeline_error);
        g_free(pipeline_text); g_free(encoder);
        if (pipeline == NULL) { g_clear_error(&pipeline_error); continue; }
        GstAppSink *sink = GST_APP_SINK(gst_bin_get_by_name(GST_BIN(pipeline), "dieter_sink"));
        GstElement *encoder_element = gst_bin_get_by_name(GST_BIN(pipeline), "dieter_encoder");
        GstElement *rate = gst_bin_get_by_name(GST_BIN(pipeline), "dieter_rate");
        if (sink == NULL || encoder_element == NULL || rate == NULL) {
            if (sink != NULL) gst_object_unref(sink);
            if (encoder_element != NULL) gst_object_unref(encoder_element);
            if (rate != NULL) gst_object_unref(rate);
            gst_object_unref(pipeline);
            continue;
        }
        stream->pipeline = pipeline;
        stream->sink = sink;
        stream->encoder = encoder_element;
        stream->rate = rate;
        stream->encoder_name = encoder_description(candidates[i]);
        g_strlcpy(stream->encoder_factory, candidates[i], sizeof(stream->encoder_factory));
        g_mutex_lock(&stream->lock);
        stream->stopping = FALSE; stream->credit = TRUE; stream->generation++;
        g_mutex_unlock(&stream->lock);
        g_signal_connect(stream->sink, "new-sample", G_CALLBACK(new_sample), stream);
        GstStateChangeReturn state = gst_element_set_state(pipeline, GST_STATE_PLAYING);
        if (state != GST_STATE_CHANGE_FAILURE)
            state = gst_element_get_state(pipeline, NULL, NULL, 8 * GST_SECOND);
        if (state == GST_STATE_CHANGE_FAILURE) {
            gst_element_set_state(pipeline, GST_STATE_NULL);
            gst_object_unref(pipeline);
            gst_object_unref(sink);
            gst_object_unref(encoder_element);
            gst_object_unref(rate);
            stream->pipeline = NULL; stream->sink = NULL; stream->encoder = NULL; stream->rate = NULL;
            g_clear_pointer(&stream->encoder_name, g_free);
            g_clear_error(&pipeline_error);
            continue;
        }
        gst_object_unref(stream->sink);
        gst_object_unref(stream->encoder);
        gst_object_unref(stream->rate);
        stream->bus_thread = g_thread_new("dieter-gst-bus", watch_bus, stream);
        started = TRUE;
    }
    g_free(source);
    if (!started) g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "no installed GStreamer H.264 encoder could start");
    return started;
}

static void capture_stream_free(gpointer data) {
    CaptureStream *stream = data;
    if (stream == NULL) return;
    stop_pipeline(stream);
    g_mutex_clear(&stream->lock);
    g_free(stream);
}

static guint hid_to_evdev(guint usage) {
    static const guint letters[] = {30,48,46,32,18,33,34,35,23,36,37,38,50,49,24,25,16,19,31,20,22,47,17,45,21,44};
    if (usage >= 4 && usage <= 29) return letters[usage - 4];
    if (usage >= 30 && usage <= 38) return usage - 28; /* 1 through 9 */
    if (usage == 39) return 11; /* 0 */
    switch (usage) {
    case 40: return 28; case 41: return 1; case 42: return 14; case 43: return 15; case 44: return 57;
    case 45: return 12; case 46: return 13; case 47: return 26; case 48: return 27; case 49: return 43;
    case 50: return 86; case 51: return 39; case 52: return 40; case 53: return 41; case 54: return 51;
    case 55: return 52; case 56: return 53; case 57: return 58;
    case 58: return 59; case 59: return 60; case 60: return 61; case 61: return 62; case 62: return 63;
    case 63: return 64; case 64: return 65; case 65: return 66; case 66: return 67; case 67: return 68; case 68: return 87; case 69: return 88;
    case 70: return 99; case 71: return 70; case 72: return 119; case 73: return 110; case 74: return 102;
    case 75: return 104; case 76: return 111; case 77: return 107; case 78: return 109;
    case 79: return 106; case 80: return 105; case 81: return 108; case 82: return 103;
    case 83: return 69; case 84: return 98; case 85: return 55; case 86: return 74; case 87: return 78;
    case 88: return 96; case 89: return 79; case 90: return 80; case 91: return 81; case 92: return 75;
    case 93: return 76; case 94: return 77; case 95: return 71; case 96: return 72; case 97: return 73;
    case 98: return 82; case 99: return 83; case 100: return 86;
    case 224: return 29; case 225: return 42; case 226: return 56; case 227: return 125;
    case 228: return 97; case 229: return 54; case 230: return 100; case 231: return 126;
    default: return 0;
    }
}

static gint portal_button(gint button) {
    if (button == 1) return 272;
    if (button == 2) return 273;
    if (button == 3) return 274;
    return 271 + button;
}

static gboolean portal_notify(CaptureApp *app, const gchar *method, GVariant *parameters, GError **error) {
    GVariant *reply = g_dbus_connection_call_sync(app->portal.bus, "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop", "org.freedesktop.portal.RemoteDesktop", method,
        parameters, NULL, G_DBUS_CALL_FLAGS_NONE, 3000, NULL, error);
    if (reply == NULL) return FALSE;
    g_variant_unref(reply);
    return TRUE;
}

static void release_input(CaptureApp *app) {
    g_mutex_lock(&app->input_lock);
    if (app->xdisplay != NULL) {
        for (guint code = 0; code < G_N_ELEMENTS(app->held_keys); code++) {
            if (app->held_keys[code]) XTestFakeKeyEvent(app->xdisplay, code, False, CurrentTime);
            app->held_keys[code] = FALSE;
        }
        for (guint button = 1; button < G_N_ELEMENTS(app->held_buttons); button++) {
            if (app->held_buttons[button]) XTestFakeButtonEvent(app->xdisplay, button, False, CurrentTime);
            app->held_buttons[button] = FALSE;
        }
        XFlush(app->xdisplay);
    } else if (app->portal.bus != NULL && app->portal.session_path != NULL) {
        GVariantBuilder empty;
        for (guint code = 0; code < G_N_ELEMENTS(app->held_keys); code++) if (app->held_keys[code]) {
            g_variant_builder_init(&empty, G_VARIANT_TYPE_VARDICT);
            (void)portal_notify(app, "NotifyKeyboardKeycode", g_variant_new("(o@a{sv}iu)", app->portal.session_path,
                g_variant_builder_end(&empty), (gint32)code, 0U), NULL);
            app->held_keys[code] = FALSE;
        }
        for (guint button = 1; button < G_N_ELEMENTS(app->held_buttons); button++) if (app->held_buttons[button]) {
            g_variant_builder_init(&empty, G_VARIANT_TYPE_VARDICT);
            (void)portal_notify(app, "NotifyPointerButton", g_variant_new("(o@a{sv}iu)", app->portal.session_path,
                g_variant_builder_end(&empty), portal_button((gint)button), 0U), NULL);
            app->held_buttons[button] = FALSE;
        }
    }
    g_mutex_unlock(&app->input_lock);
}

static gboolean object_int(JsonObject *object, const gchar *name, gint64 *value) {
    if (!json_object_has_member(object, name)) { *value = 0; return TRUE; }
    JsonNode *node = json_object_get_member(object, name);
    if (node == NULL || !JSON_NODE_HOLDS_VALUE(node)) return FALSE;
    *value = json_node_get_int(node);
    return TRUE;
}

static gboolean handle_input(CaptureApp *app, CaptureStream *stream, JsonObject *input, GError **error) {
    const gchar *kind = json_object_get_string_member_with_default(input, "kind", "");
    if (g_str_equal(kind, "release_all")) { release_input(app); return TRUE; }
    if (!app->allow_input) { g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "remote input is disabled"); return FALSE; }
    gint64 generation = 0;
    if (!object_int(input, "generation", &generation) || (generation != 0 && (guint64)generation != stream->generation)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "stale input display generation"); return FALSE;
    }
    if (app->synthetic) return TRUE;
    gint64 x = 0, y = 0, button = 0, physical = 0, key = 0;
    (void)object_int(input, "x", &x); (void)object_int(input, "y", &y); (void)object_int(input, "button", &button);
    (void)object_int(input, "physical_key", &physical); (void)object_int(input, "key_code", &key);
    gboolean down = json_object_get_boolean_member_with_default(input, "down", FALSE);
    if ((x < 0 || x > 1000000 || y < 0 || y > 1000000) &&
        (g_str_equal(kind, "pointer_move") || g_str_equal(kind, "pointer_button"))) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "pointer coordinate is out of bounds"); return FALSE;
    }
    g_mutex_lock(&app->input_lock);
    gboolean ok = TRUE;
    if (app->xdisplay != NULL) {
        gint px = stream->x + (gint)((gint64)MAX(0, stream->source_width - 1) * x / 1000000);
        gint py = stream->y + (gint)((gint64)MAX(0, stream->source_height - 1) * y / 1000000);
        if (g_str_equal(kind, "pointer_move")) XTestFakeMotionEvent(app->xdisplay, DefaultScreen(app->xdisplay), px, py, CurrentTime);
        else if (g_str_equal(kind, "pointer_button")) {
            gint mapped = button == 2 ? 3 : button == 3 ? 2 : (gint)button;
            if (mapped < 1 || mapped > 9) ok = FALSE;
            else { XTestFakeMotionEvent(app->xdisplay, DefaultScreen(app->xdisplay), px, py, CurrentTime); XTestFakeButtonEvent(app->xdisplay, (unsigned int)mapped, down, CurrentTime); app->held_buttons[mapped] = down; }
        } else if (g_str_equal(kind, "scroll")) {
            gdouble dx = json_object_get_double_member_with_default(input, "delta_x", 0);
            gdouble dy = json_object_get_double_member_with_default(input, "delta_y", 0);
            gint vertical = dy < 0 ? 4 : 5, horizontal = dx < 0 ? 6 : 7;
            guint vertical_count = (guint)MIN(20.0, ceil(fabs(dy)));
            guint horizontal_count = (guint)MIN(20.0, ceil(fabs(dx)));
            for (guint i = 0; i < vertical_count; i++) { XTestFakeButtonEvent(app->xdisplay, (unsigned int)vertical, True, CurrentTime); XTestFakeButtonEvent(app->xdisplay, (unsigned int)vertical, False, CurrentTime); }
            for (guint i = 0; i < horizontal_count; i++) { XTestFakeButtonEvent(app->xdisplay, (unsigned int)horizontal, True, CurrentTime); XTestFakeButtonEvent(app->xdisplay, (unsigned int)horizontal, False, CurrentTime); }
        } else if (g_str_equal(kind, "key")) {
            guint evdev = hid_to_evdev(physical > 0 ? (guint)physical : (guint)key);
            guint code = evdev + 8;
            if (evdev == 0 || code >= G_N_ELEMENTS(app->held_keys)) ok = FALSE;
            else { XTestFakeKeyEvent(app->xdisplay, code, down, CurrentTime); app->held_keys[code] = down; }
        } else ok = FALSE;
        XFlush(app->xdisplay);
    } else if (app->portal.bus != NULL && app->portal.session_path != NULL) {
        GVariantBuilder empty;
        g_variant_builder_init(&empty, G_VARIANT_TYPE_VARDICT);
        if (g_str_equal(kind, "pointer_move")) {
            gdouble px = (gdouble)MAX(0, stream->source_width - 1) * (gdouble)x / 1000000.0;
            gdouble py = (gdouble)MAX(0, stream->source_height - 1) * (gdouble)y / 1000000.0;
            ok = portal_notify(app, "NotifyPointerMotionAbsolute", g_variant_new("(o@a{sv}udd)", app->portal.session_path,
                g_variant_builder_end(&empty), app->portal.node_id, px, py), error);
        } else if (g_str_equal(kind, "pointer_button") && button >= 1 && button <= 9) {
            ok = portal_notify(app, "NotifyPointerButton", g_variant_new("(o@a{sv}iu)", app->portal.session_path,
                g_variant_builder_end(&empty), portal_button((gint)button), down ? 1U : 0U), error);
            if (ok) app->held_buttons[button] = down;
        } else if (g_str_equal(kind, "scroll")) {
            gdouble dx = json_object_get_double_member_with_default(input, "delta_x", 0);
            gdouble dy = json_object_get_double_member_with_default(input, "delta_y", 0);
            ok = portal_notify(app, "NotifyPointerAxis", g_variant_new("(o@a{sv}dd)", app->portal.session_path,
                g_variant_builder_end(&empty), dx, dy), error);
        } else if (g_str_equal(kind, "key")) {
            guint evdev = hid_to_evdev(physical > 0 ? (guint)physical : (guint)key);
            if (evdev == 0 || evdev >= G_N_ELEMENTS(app->held_keys)) ok = FALSE;
            else {
                ok = portal_notify(app, "NotifyKeyboardKeycode", g_variant_new("(o@a{sv}iu)", app->portal.session_path,
                    g_variant_builder_end(&empty), (gint32)evdev, down ? 1U : 0U), error);
                if (ok) app->held_keys[evdev] = down;
            }
        } else ok = FALSE;
    } else ok = FALSE;
    g_mutex_unlock(&app->input_lock);
    if (!ok && (error == NULL || *error == NULL)) g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "input event is unsupported");
    return ok;
}

static gboolean parse_config(JsonObject *object, StreamConfig *config, GError **error) {
    const gchar *display = json_object_get_string_member_with_default(object, "display_id", "primary");
    gint64 width = json_object_get_int_member_with_default(object, "max_width", 3840);
    gint64 height = json_object_get_int_member_with_default(object, "max_height", 2160);
    gint64 fps = json_object_get_int_member_with_default(object, "fps", 60);
    gint64 bitrate = json_object_get_int_member_with_default(object, "bitrate_kbps", 12000);
    if (strlen(display) > 64 || width < 320 || width > 3840 || height < 180 || height > 2160 ||
        fps < 1 || fps > 120 || bitrate < 100 || bitrate > 100000) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "invalid stream configuration");
        return FALSE;
    }
    g_strlcpy(config->display_id, display, sizeof(config->display_id));
    config->max_width = (gint)width; config->max_height = (gint)height;
    config->fps = (gint)fps; config->bitrate_kbps = (gint)bitrate;
    config->embedded_cursor = json_object_get_boolean_member_with_default(object, "embedded_cursor", FALSE);
    return TRUE;
}

static CaptureStream *lookup_stream(CaptureApp *app, guint64 stream_id) {
    guint64 key = stream_id;
    return g_hash_table_lookup(app->streams, &key);
}

static gboolean handle_command(CaptureApp *app, JsonObject *command) {
    gint64 version = json_object_get_int_member_with_default(command, "version", 0);
    gint64 id_value = json_object_get_int_member_with_default(command, "id", 0);
    gint64 stream_value = json_object_get_int_member_with_default(command, "stream_id", app->multiplex ? 0 : 1);
    const gchar *kind = json_object_get_string_member_with_default(command, "kind", "");
    guint64 id = id_value > 0 ? (guint64)id_value : 0;
    guint64 stream_id = stream_value > 0 ? (guint64)stream_value : (app->multiplex ? 0 : 1);
    GError *error = NULL;
    if (version != 2 || id == 0 || strlen(kind) > 32) {
        emit_event(app, stream_id, id, "invalid native command", NULL);
        return TRUE;
    }

    g_mutex_lock(&app->streams_lock);
    CaptureStream *stream = lookup_stream(app, stream_id);
    if (g_str_equal(kind, "create")) {
        if (!app->multiplex || stream_id == 0 || stream != NULL || g_hash_table_size(app->streams) >= MAX_STREAMS) {
            g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "invalid or duplicate capture stream");
        } else {
            JsonObject *configuration = json_object_get_object_member(command, "configuration");
            stream = g_new0(CaptureStream, 1);
            stream->app = app; stream->id = stream_id; stream->generation = 0;
            g_strlcpy(stream->profile, json_object_get_string_member_with_default(command, "profile", "high"), sizeof(stream->profile));
            g_mutex_init(&stream->lock);
            if (configuration == NULL || !parse_config(configuration, &stream->config, &error)) {
                capture_stream_free(stream); stream = NULL;
            } else {
                if (!app->synthetic) stream->config.embedded_cursor = TRUE;
                if (!start_pipeline(stream, &error)) {
                    capture_stream_free(stream); stream = NULL;
                } else {
                    guint64 *key = g_new(guint64, 1); *key = stream_id;
                    g_hash_table_insert(app->streams, key, stream);
                }
            }
        }
    } else if (stream == NULL) {
        g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "capture stream is unavailable");
    } else if (g_str_equal(kind, "remove")) {
        guint64 key = stream_id;
        release_input(app);
        g_hash_table_remove(app->streams, &key);
        stream = NULL;
    } else if (g_str_equal(kind, "frame_consumed")) {
        g_mutex_lock(&stream->lock); stream->credit = TRUE; g_mutex_unlock(&stream->lock);
    } else if (g_str_equal(kind, "configure")) {
        JsonObject *configuration = json_object_get_object_member(command, "configuration");
        StreamConfig next;
        if (configuration == NULL || !parse_config(configuration, &next, &error)) {
        } else {
            if (!app->synthetic) next.embedded_cursor = TRUE;
            if (next.max_width == stream->config.max_width && next.max_height == stream->config.max_height &&
                   next.embedded_cursor == stream->config.embedded_cursor &&
                   g_str_equal(next.display_id, stream->config.display_id)) {
                stream->config.fps = next.fps;
                stream->config.bitrate_kbps = next.bitrate_kbps;
                if (stream->encoder != NULL) {
                    guint bitrate = (guint)next.bitrate_kbps;
                    if (g_str_equal(stream->encoder_factory, "openh264enc")) bitrate *= 1000U;
                    g_object_set(stream->encoder, "bitrate", bitrate, NULL);
                }
            } else {
                release_input(app);
                stop_pipeline(stream);
                stream->config = next;
                if (!start_pipeline(stream, &error)) stream = NULL;
            }
        }
    } else if (g_str_equal(kind, "refresh")) {
        if (stream->pipeline != NULL) {
            GstEvent *event = gst_video_event_new_downstream_force_key_unit(GST_CLOCK_TIME_NONE,
                GST_CLOCK_TIME_NONE, GST_CLOCK_TIME_NONE, TRUE, 0);
            (void)gst_element_send_event(stream->pipeline, event);
        }
    } else if (g_str_equal(kind, "input")) {
        JsonObject *input = json_object_get_object_member(command, "input");
        if (input == NULL || !handle_input(app, stream, input, &error)) {
        }
    } else if (g_str_equal(kind, "heartbeat") || g_str_equal(kind, "frame_sending") ||
               g_str_equal(kind, "reference_ack") || g_str_equal(kind, "display_changed")) {
        /* Protocol-compatible no-op: GStreamer has no Apple LTR/overlap primitive. */
    } else {
        g_set_error(&error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "unsupported native command %s", kind);
    }
    const gchar *message = error != NULL ? error->message : NULL;
    emit_event(app, stream_id, id, message, stream != NULL && (g_str_equal(kind, "create") || g_str_equal(kind, "configure")) ? stream : NULL);
    g_mutex_unlock(&app->streams_lock);
    g_clear_error(&error);
    return TRUE;
}

static gboolean run_commands(CaptureApp *app) {
    gchar *line = NULL;
    size_t capacity = 0;
    gint64 last_command = g_get_monotonic_time();
    while (!feof(stdin)) {
        struct pollfd descriptor = {.fd = STDIN_FILENO, .events = POLLIN};
        gint polled = poll(&descriptor, 1, 500);
        if (polled < 0 && errno == EINTR) continue;
        if (polled < 0) { g_free(line); return FALSE; }
        if (polled == 0) {
            if (g_get_monotonic_time() - last_command > 3 * G_TIME_SPAN_SECOND) {
                diagnostic("native daemon heartbeat expired");
                g_free(line);
                return TRUE;
            }
            continue;
        }
        if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 && (descriptor.revents & POLLIN) == 0) break;
        ssize_t length = getline(&line, &capacity, stdin);
        if (length < 0) break;
        last_command = g_get_monotonic_time();
        if (length == 0 || length > MAX_COMMAND_BYTES) { g_free(line); return FALSE; }
        JsonParser *parser = json_parser_new();
        GError *error = NULL;
        gboolean parsed = json_parser_load_from_data(parser, line, length, &error);
        if (!parsed || !JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser))) {
            diagnostic("invalid native command: %s", error != NULL ? error->message : "object expected");
            g_clear_error(&error); g_object_unref(parser); g_free(line); return FALSE;
        }
        (void)handle_command(app, json_node_get_object(json_parser_get_root(parser)));
        g_object_unref(parser);
    }
    g_free(line);
    return TRUE;
}

static gboolean parse_boolean(const gchar *value) { return value != NULL && g_str_equal(value, "true"); }

static gboolean parse_options(int argc, char **argv, Options *options, GError **error) {
    *options = (Options){.event_fd = -1, .fps = 60, .bitrate_kbps = 12000,
        .max_width = 3840, .max_height = 2160, .display_id = g_strdup("primary"),
        .profile = g_strdup("high"), .codec = g_strdup("H264")};
    for (int i = 1; i < argc; i++) {
        const gchar *name = argv[i];
        if (g_str_equal(name, "--capabilities")) { options->capabilities = TRUE; continue; }
        if (g_str_equal(name, "--check-control")) { options->check_control = TRUE; continue; }
        if (g_str_equal(name, "--request-control")) { options->request_control = TRUE; continue; }
        if (g_str_equal(name, "--clipboard-service") || g_str_equal(name, "--display-service")) {
            g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "%s is not supported on Linux", name); return FALSE;
        }
        if (i + 1 >= argc) { g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "missing value for %s", name); return FALSE; }
        const gchar *value = argv[++i];
        if (g_str_equal(name, "--multiplex")) options->multiplex = parse_boolean(value);
        else if (g_str_equal(name, "--synthetic")) options->synthetic = parse_boolean(value);
        else if (g_str_equal(name, "--allow-input")) options->allow_input = parse_boolean(value);
        else if (g_str_equal(name, "--embedded-cursor")) options->embedded_cursor = parse_boolean(value);
        else if (g_str_equal(name, "--event-fd")) options->event_fd = atoi(value);
        else if (g_str_equal(name, "--fps")) options->fps = atoi(value);
        else if (g_str_equal(name, "--bitrate-kbps")) options->bitrate_kbps = atoi(value);
        else if (g_str_equal(name, "--max-width")) options->max_width = atoi(value);
        else if (g_str_equal(name, "--max-height")) options->max_height = atoi(value);
        else if (g_str_equal(name, "--display-id")) { g_free(options->display_id); options->display_id = g_strdup(value); }
        else if (g_str_equal(name, "--profile")) { g_free(options->profile); options->profile = g_strdup(value); }
        else if (g_str_equal(name, "--codec")) { g_free(options->codec); options->codec = g_strdup(value); }
        else if (g_str_equal(name, "--portal-state")) { g_free(options->portal_state); options->portal_state = g_strdup(value); }
        else if (g_str_equal(name, "--frame-credits") || g_str_equal(name, "--reference-recovery")) { /* accepted compatibility flag */ }
        else { g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "unknown option %s", name); return FALSE; }
    }
    if (!g_str_equal(options->codec, "H264")) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Linux capture currently supports H.264 only"); return FALSE;
    }
    return TRUE;
}

static int control_probe(void) {
    gchar *type = session_type();
    int result = 1;
    if (g_str_equal(type, "x11")) {
        Display *display = XOpenDisplay(NULL);
        if (display != NULL) {
            int event = 0, error = 0, major = 0, minor = 0;
            result = XTestQueryExtension(display, &event, &error, &major, &minor) ? 0 : 1;
            XCloseDisplay(display);
        }
        if (result != 0) diagnostic("X11 XTest input extension is unavailable");
    } else if (g_str_equal(type, "wayland")) {
        result = portal_version("org.freedesktop.portal.RemoteDesktop") > 0 ? 0 : 1;
        if (result != 0) diagnostic("XDG RemoteDesktop portal is unavailable");
    } else diagnostic("No supported graphical login session is active");
    g_free(type);
    return result;
}

static gboolean initialize_direct_stream(CaptureApp *app, const Options *options, GError **error) {
    CaptureStream *stream = g_new0(CaptureStream, 1);
    stream->app = app; stream->id = 1;
    g_strlcpy(stream->profile, options->profile, sizeof(stream->profile));
    g_mutex_init(&stream->lock);
    g_strlcpy(stream->config.display_id, options->display_id, sizeof(stream->config.display_id));
    stream->config.max_width = options->max_width; stream->config.max_height = options->max_height;
    stream->config.fps = options->fps; stream->config.bitrate_kbps = options->bitrate_kbps;
    stream->config.embedded_cursor = options->embedded_cursor;
    if (!app->synthetic) stream->config.embedded_cursor = TRUE;
    if (!start_pipeline(stream, error)) { capture_stream_free(stream); return FALSE; }
    guint64 *key = g_new(guint64, 1); *key = 1;
    g_hash_table_insert(app->streams, key, stream);
    return TRUE;
}

int main(int argc, char **argv) {
    discover_graphical_environment();
    gst_init(&argc, &argv);
    XInitThreads();
    Options options;
    GError *error = NULL;
    if (!parse_options(argc, argv, &options, &error)) {
        diagnostic("%s", error->message); g_clear_error(&error); return 2;
    }
    if (options.capabilities) return print_capabilities(&options);
    if (options.check_control || options.request_control) return control_probe();
    if (options.event_fd != -1 && options.event_fd != 3) { diagnostic("native event fd must be 3"); return 2; }

    CaptureApp app = {.multiplex = options.multiplex, .synthetic = options.synthetic,
        .allow_input = options.allow_input, .event_fd = options.event_fd};
    gint discard_events = -1;
    if (app.event_fd < 0) {
        discard_events = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (discard_events < 0) { diagnostic("open /dev/null: %s", g_strerror(errno)); return 1; }
        app.event_fd = discard_events;
    }
    app.portal.pipewire_fd = -1;
    app.portal.state_path = g_strdup(options.portal_state);
    app.session_type = session_type();
    app.streams = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, capture_stream_free);
    g_mutex_init(&app.streams_lock); g_mutex_init(&app.output_lock); g_mutex_init(&app.event_lock); g_mutex_init(&app.input_lock);
    if (!app.synthetic && g_str_equal(app.session_type, "x11") && app.allow_input) {
        app.xdisplay = XOpenDisplay(NULL);
        if (app.xdisplay != NULL) {
            int event = 0, xerror = 0, major = 0, minor = 0;
            app.xinput_supported = XTestQueryExtension(app.xdisplay, &event, &xerror, &major, &minor);
        }
        if (!app.xinput_supported) { diagnostic("X11 XTest input extension is unavailable"); return 1; }
    }
    const gchar *magic = app.multiplex ? "DTH3" : "DTH2";
    if (!write_all(STDOUT_FILENO, (const guint8 *)magic, 4)) return 1;
    if (!app.multiplex && !initialize_direct_stream(&app, &options, &error)) {
        diagnostic("%s", error->message); g_clear_error(&error); return 1;
    }
    gboolean ok = run_commands(&app);
    release_input(&app);
    g_hash_table_remove_all(app.streams);
    portal_close(&app.portal);
    if (app.xdisplay != NULL) XCloseDisplay(app.xdisplay);
    g_hash_table_unref(app.streams);
    g_free(app.portal.state_path); g_free(app.session_type);
    g_mutex_clear(&app.streams_lock); g_mutex_clear(&app.output_lock); g_mutex_clear(&app.event_lock); g_mutex_clear(&app.input_lock);
    g_free(options.display_id); g_free(options.profile); g_free(options.codec); g_free(options.portal_state);
    if (discard_events >= 0) close(discard_events);
    return ok ? 0 : 1;
}
