#ifndef OKMPV_BRIDGE_H
#define OKMPV_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OKMPVClient OKMPVClient;
typedef struct OKMPVRenderContext OKMPVRenderContext;

typedef void *(*OKMPVGetProcAddress)(void *context, const char *name);
typedef void (*OKMPVRenderUpdateCallback)(void *context);

typedef struct OKMPVEvent {
    int event_id;
    int error;
    uint64_t reply_userdata;
    int property_format;
    const char *property_name;
    const char *string_value;
    double double_value;
    int64_t int64_value;
    int flag_value;
    int end_file_reason;
} OKMPVEvent;

OKMPVClient *okmpv_create(void);
int okmpv_initialize(OKMPVClient *client);
void okmpv_wakeup(OKMPVClient *client);
void okmpv_destroy(OKMPVClient *client);

int okmpv_set_option_string(
    OKMPVClient *client,
    const char *name,
    const char *value
);
int okmpv_command(
    OKMPVClient *client,
    int argument_count,
    const char *const *arguments
);
int okmpv_set_property_string(
    OKMPVClient *client,
    const char *name,
    const char *value
);
int okmpv_get_property_string(
    OKMPVClient *client,
    const char *name,
    char *value,
    int value_capacity
);
int okmpv_set_property_double(
    OKMPVClient *client,
    const char *name,
    double value
);
int okmpv_set_property_flag(
    OKMPVClient *client,
    const char *name,
    int value
);
int okmpv_set_property_string_array(
    OKMPVClient *client,
    const char *name,
    int value_count,
    const char *const *values
);
int okmpv_observe_property(
    OKMPVClient *client,
    uint64_t identifier,
    const char *name,
    int format
);
int okmpv_wait_event(
    OKMPVClient *client,
    double timeout,
    OKMPVEvent *event
);
int okmpv_track_count(OKMPVClient *client);
int okmpv_track_at(
    OKMPVClient *client,
    int index,
    int64_t *identifier,
    char *type,
    int type_capacity,
    char *title,
    int title_capacity,
    char *language,
    int language_capacity,
    int *selected
);

const char *okmpv_error_string(int error);
const char *okmpv_client_api_version_string(void);
int okmpv_event_size(void);

/*
 * Inspect the first video stream with FFmpeg without decoding frames.
 * Returns 1 for Dolby Vision, 0 when no Dolby Vision configuration is
 * present, and a negative AVERROR code when the input cannot be probed.
 */
int okmpv_probe_dolby_vision(
    const char *url,
    int header_count,
    const char *const *headers,
    int *profile,
    int *level
);

/* Probe Dolby Vision metadata together with the actual FFmpeg container. */
int okmpv_probe_media_info(
    const char *url,
    int header_count,
    const char *const *headers,
    int *profile,
    int *level,
    double *duration_seconds,
    char *container_name,
    int container_name_capacity
);

int okmpv_render_create(
    OKMPVClient *client,
    OKMPVGetProcAddress get_proc_address,
    void *get_proc_address_context,
    int advanced_control,
    OKMPVRenderContext **render_context
);
void okmpv_render_set_update_callback(
    OKMPVRenderContext *render_context,
    OKMPVRenderUpdateCallback callback,
    void *callback_context
);
uint64_t okmpv_render_update(OKMPVRenderContext *render_context);
int okmpv_render(
    OKMPVRenderContext *render_context,
    int framebuffer,
    int width,
    int height,
    int flip_y
);
int okmpv_render_skip(OKMPVRenderContext *render_context);
void okmpv_render_report_swap(OKMPVRenderContext *render_context);
void okmpv_render_destroy(OKMPVRenderContext *render_context);

#ifdef __cplusplus
}
#endif

#endif
