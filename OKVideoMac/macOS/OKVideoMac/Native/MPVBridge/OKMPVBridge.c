#include "OKMPVBridge.h"

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavutil/dovi_meta.h>

#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

struct OKMPVClient {
    mpv_handle *handle;
    char property_name[256];
    char string_value[4096];
};

struct OKMPVRenderContext {
    mpv_render_context *context;
};

static char *join_http_headers(
    int header_count,
    const char *const *headers
) {
    if (header_count <= 0) {
        return NULL;
    }
    size_t length = 1;
    for (int index = 0; index < header_count; index++) {
        if (headers[index] == NULL) {
            return NULL;
        }
        length += strlen(headers[index]) + 2;
    }
    char *joined = calloc(length, 1);
    if (joined == NULL) {
        return NULL;
    }
    for (int index = 0; index < header_count; index++) {
        strcat(joined, headers[index]);
        strcat(joined, "\r\n");
    }
    return joined;
}

int okmpv_probe_media_info(
    const char *url,
    int header_count,
    const char *const *headers,
    int *profile,
    int *level,
    double *duration_seconds,
    char *container_name,
    int container_name_capacity
) {
    if (url == NULL || profile == NULL || level == NULL || header_count < 0 ||
        (header_count > 0 && headers == NULL) || container_name_capacity < 0 ||
        (container_name_capacity > 0 && container_name == NULL)) {
        return AVERROR(EINVAL);
    }
    *profile = -1;
    *level = -1;
    if (duration_seconds != NULL) {
        *duration_seconds = 0;
    }
    if (container_name_capacity > 0) {
        container_name[0] = '\0';
    }

    AVFormatContext *format_context = NULL;
    AVDictionary *options = NULL;
    char *joined_headers = join_http_headers(header_count, headers);
    if (header_count > 0 && joined_headers == NULL) {
        return AVERROR(ENOMEM);
    }
    if (joined_headers != NULL) {
        av_dict_set(&options, "headers", joined_headers, 0);
    }
    // This probe runs before playback begins. Opening the container header is
    // sufficient for both the demuxer name and Dolby Vision configuration.
    // Do not ask FFmpeg to scan packets: cloud-drive proxy URLs can represent
    // multi-gigabyte files and a deep stream-info scan may issue many Range
    // requests before the player is even created.
    av_dict_set(&options, "rw_timeout", "8000000", 0);

    int result = avformat_open_input(&format_context, url, NULL, &options);
    av_dict_free(&options);
    free(joined_headers);
    if (result < 0) {
        return result;
    }
    if (container_name_capacity > 0 && format_context->iformat != NULL) {
        snprintf(
            container_name,
            (size_t)container_name_capacity,
            "%s",
            format_context->iformat->name != NULL
                ? format_context->iformat->name
                : ""
        );
    }
    if (duration_seconds != NULL &&
        format_context->duration != AV_NOPTS_VALUE &&
        format_context->duration > 0) {
        *duration_seconds =
            (double)format_context->duration / (double)AV_TIME_BASE;
    }

    int found = 0;
    for (unsigned int index = 0; index < format_context->nb_streams; index++) {
        const AVCodecParameters *parameters =
            format_context->streams[index]->codecpar;
        if (parameters == NULL || parameters->codec_type != AVMEDIA_TYPE_VIDEO) {
            continue;
        }
        const AVPacketSideData *side_data = av_packet_side_data_get(
            parameters->coded_side_data,
            parameters->nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        );
        if (side_data != NULL &&
            side_data->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
            const AVDOVIDecoderConfigurationRecord *configuration =
                (const AVDOVIDecoderConfigurationRecord *)side_data->data;
            *profile = configuration->dv_profile;
            *level = configuration->dv_level;
            found = 1;
            break;
        }
    }
    avformat_close_input(&format_context);
    return found;
}

int okmpv_probe_dolby_vision(
    const char *url,
    int header_count,
    const char *const *headers,
    int *profile,
    int *level
) {
    return okmpv_probe_media_info(
        url,
        header_count,
        headers,
        profile,
        level,
        NULL,
        NULL,
        0
    );
}

static void copy_string(char *destination, size_t size, const char *source) {
    if (size == 0) {
        return;
    }
    if (source == NULL) {
        destination[0] = '\0';
        return;
    }
    snprintf(destination, size, "%s", source);
}

OKMPVClient *okmpv_create(void) {
    OKMPVClient *client = calloc(1, sizeof(OKMPVClient));
    if (client == NULL) {
        return NULL;
    }
    client->handle = mpv_create();
    if (client->handle == NULL) {
        free(client);
        return NULL;
    }
    return client;
}

int okmpv_initialize(OKMPVClient *client) {
    if (client == NULL || client->handle == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    return mpv_initialize(client->handle);
}

void okmpv_wakeup(OKMPVClient *client) {
    if (client != NULL && client->handle != NULL) {
        mpv_wakeup(client->handle);
    }
}

void okmpv_destroy(OKMPVClient *client) {
    if (client == NULL) {
        return;
    }
    if (client->handle != NULL) {
        mpv_terminate_destroy(client->handle);
        client->handle = NULL;
    }
    free(client);
}

int okmpv_set_option_string(
    OKMPVClient *client,
    const char *name,
    const char *value
) {
    if (client == NULL || client->handle == NULL || name == NULL || value == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    return mpv_set_option_string(client->handle, name, value);
}

int okmpv_command(
    OKMPVClient *client,
    int argument_count,
    const char *const *arguments
) {
    if (client == NULL || client->handle == NULL || argument_count < 1 ||
        arguments == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    const char **terminated = calloc(
        (size_t)argument_count + 1,
        sizeof(const char *)
    );
    if (terminated == NULL) {
        return MPV_ERROR_NOMEM;
    }
    for (int index = 0; index < argument_count; index++) {
        terminated[index] = arguments[index];
    }
    int result = mpv_command(client->handle, terminated);
    free(terminated);
    return result;
}

int okmpv_set_property_string(
    OKMPVClient *client,
    const char *name,
    const char *value
) {
    if (client == NULL || client->handle == NULL || name == NULL || value == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    return mpv_set_property_string(client->handle, name, value);
}

int okmpv_set_property_double(
    OKMPVClient *client,
    const char *name,
    double value
) {
    if (client == NULL || client->handle == NULL || name == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    return mpv_set_property(client->handle, name, MPV_FORMAT_DOUBLE, &value);
}

int okmpv_set_property_flag(
    OKMPVClient *client,
    const char *name,
    int value
) {
    if (client == NULL || client->handle == NULL || name == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    int flag = value != 0;
    return mpv_set_property(client->handle, name, MPV_FORMAT_FLAG, &flag);
}

int okmpv_set_property_string_array(
    OKMPVClient *client,
    const char *name,
    int value_count,
    const char *const *values
) {
    if (client == NULL || client->handle == NULL || name == NULL ||
        value_count < 0 || (value_count > 0 && values == NULL)) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    mpv_node *items = NULL;
    if (value_count > 0) {
        items = calloc((size_t)value_count, sizeof(mpv_node));
        if (items == NULL) {
            return MPV_ERROR_NOMEM;
        }
        for (int index = 0; index < value_count; index++) {
            items[index].format = MPV_FORMAT_STRING;
            items[index].u.string = (char *)values[index];
        }
    }
    mpv_node_list list = {
        .num = value_count,
        .values = items,
        .keys = NULL
    };
    mpv_node node = {
        .u.list = &list,
        .format = MPV_FORMAT_NODE_ARRAY
    };
    int result = mpv_set_property(client->handle, name, MPV_FORMAT_NODE, &node);
    free(items);
    return result;
}

int okmpv_observe_property(
    OKMPVClient *client,
    uint64_t identifier,
    const char *name,
    int format
) {
    if (client == NULL || client->handle == NULL || name == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    return mpv_observe_property(
        client->handle,
        identifier,
        name,
        (mpv_format)format
    );
}

int okmpv_wait_event(
    OKMPVClient *client,
    double timeout,
    OKMPVEvent *output
) {
    if (client == NULL || client->handle == NULL || output == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    memset(output, 0, sizeof(OKMPVEvent));
    mpv_event *event = mpv_wait_event(client->handle, timeout);
    if (event == NULL) {
        return MPV_ERROR_GENERIC;
    }

    output->event_id = event->event_id;
    output->error = event->error;
    output->reply_userdata = event->reply_userdata;

    if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && event->data != NULL) {
        mpv_event_property *property = event->data;
        copy_string(
            client->property_name,
            sizeof(client->property_name),
            property->name
        );
        output->property_name = client->property_name;
        output->property_format = property->format;
        if (property->data != NULL) {
            switch (property->format) {
                case MPV_FORMAT_STRING:
                case MPV_FORMAT_OSD_STRING: {
                    const char *value = *(char **)property->data;
                    copy_string(
                        client->string_value,
                        sizeof(client->string_value),
                        value
                    );
                    output->string_value = client->string_value;
                    break;
                }
                case MPV_FORMAT_DOUBLE:
                    output->double_value = *(double *)property->data;
                    break;
                case MPV_FORMAT_INT64:
                    output->int64_value = *(int64_t *)property->data;
                    break;
                case MPV_FORMAT_FLAG:
                    output->flag_value = *(int *)property->data;
                    break;
                default:
                    break;
            }
        }
    } else if (event->event_id == MPV_EVENT_END_FILE && event->data != NULL) {
        mpv_event_end_file *end_file = event->data;
        output->end_file_reason = end_file->reason;
        output->error = end_file->error;
    }
    return 0;
}

static mpv_node *map_value(mpv_node *node, const char *key) {
    if (node == NULL || node->format != MPV_FORMAT_NODE_MAP ||
        node->u.list == NULL || key == NULL) {
        return NULL;
    }
    for (int index = 0; index < node->u.list->num; index++) {
        const char *candidate = node->u.list->keys[index];
        if (candidate != NULL && strcmp(candidate, key) == 0) {
            return &node->u.list->values[index];
        }
    }
    return NULL;
}

int okmpv_track_count(OKMPVClient *client) {
    if (client == NULL || client->handle == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    mpv_node tracks = {0};
    int result = mpv_get_property(
        client->handle,
        "track-list",
        MPV_FORMAT_NODE,
        &tracks
    );
    if (result < 0) {
        return result;
    }
    int count = 0;
    if (tracks.format == MPV_FORMAT_NODE_ARRAY && tracks.u.list != NULL) {
        count = tracks.u.list->num;
    }
    mpv_free_node_contents(&tracks);
    return count;
}

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
) {
    if (client == NULL || client->handle == NULL || index < 0 ||
        identifier == NULL || type == NULL || type_capacity < 1 ||
        title == NULL || title_capacity < 1 || language == NULL ||
        language_capacity < 1 || selected == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    mpv_node tracks = {0};
    int result = mpv_get_property(
        client->handle,
        "track-list",
        MPV_FORMAT_NODE,
        &tracks
    );
    if (result < 0) {
        return result;
    }
    if (tracks.format != MPV_FORMAT_NODE_ARRAY || tracks.u.list == NULL ||
        index >= tracks.u.list->num) {
        mpv_free_node_contents(&tracks);
        return MPV_ERROR_INVALID_PARAMETER;
    }

    mpv_node *track = &tracks.u.list->values[index];
    mpv_node *id_node = map_value(track, "id");
    mpv_node *type_node = map_value(track, "type");
    mpv_node *title_node = map_value(track, "title");
    mpv_node *language_node = map_value(track, "lang");
    mpv_node *selected_node = map_value(track, "selected");

    *identifier = id_node != NULL && id_node->format == MPV_FORMAT_INT64
        ? id_node->u.int64
        : 0;
    copy_string(
        type,
        (size_t)type_capacity,
        type_node != NULL && type_node->format == MPV_FORMAT_STRING
            ? type_node->u.string
            : ""
    );
    copy_string(
        title,
        (size_t)title_capacity,
        title_node != NULL && title_node->format == MPV_FORMAT_STRING
            ? title_node->u.string
            : ""
    );
    copy_string(
        language,
        (size_t)language_capacity,
        language_node != NULL && language_node->format == MPV_FORMAT_STRING
            ? language_node->u.string
            : ""
    );
    *selected = selected_node != NULL &&
        selected_node->format == MPV_FORMAT_FLAG
        ? selected_node->u.flag
        : 0;

    mpv_free_node_contents(&tracks);
    return 0;
}

const char *okmpv_error_string(int error) {
    return mpv_error_string(error);
}

const char *okmpv_client_api_version_string(void) {
    static char version[32];
    unsigned long value = mpv_client_api_version();
    snprintf(
        version,
        sizeof(version),
        "%lu.%lu",
        (value >> 16) & 0xffff,
        value & 0xffff
    );
    return version;
}

int okmpv_event_size(void) {
    return (int)sizeof(OKMPVEvent);
}

int okmpv_render_create(
    OKMPVClient *client,
    OKMPVGetProcAddress get_proc_address,
    void *get_proc_address_context,
    OKMPVRenderContext **output
) {
    if (client == NULL || client->handle == NULL || get_proc_address == NULL ||
        output == NULL) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    *output = NULL;
    OKMPVRenderContext *render_context = calloc(
        1,
        sizeof(OKMPVRenderContext)
    );
    if (render_context == NULL) {
        return MPV_ERROR_NOMEM;
    }

    mpv_opengl_init_params open_gl = {
        .get_proc_address = get_proc_address,
        .get_proc_address_ctx = get_proc_address_context
    };
    const char *api_type = MPV_RENDER_API_TYPE_OPENGL;
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)api_type},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &open_gl},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    int result = mpv_render_context_create(
        &render_context->context,
        client->handle,
        parameters
    );
    if (result < 0) {
        free(render_context);
        return result;
    }
    *output = render_context;
    return 0;
}

void okmpv_render_set_update_callback(
    OKMPVRenderContext *render_context,
    OKMPVRenderUpdateCallback callback,
    void *callback_context
) {
    if (render_context != NULL && render_context->context != NULL) {
        mpv_render_context_set_update_callback(
            render_context->context,
            callback,
            callback_context
        );
    }
}

uint64_t okmpv_render_update(OKMPVRenderContext *render_context) {
    if (render_context == NULL || render_context->context == NULL) {
        return 0;
    }
    return mpv_render_context_update(render_context->context);
}

int okmpv_render(
    OKMPVRenderContext *render_context,
    int framebuffer,
    int width,
    int height,
    int flip_y
) {
    if (render_context == NULL || render_context->context == NULL ||
        width < 1 || height < 1) {
        return MPV_ERROR_INVALID_PARAMETER;
    }
    mpv_opengl_fbo fbo = {
        .fbo = framebuffer,
        .w = width,
        .h = height,
        .internal_format = 0
    };
    int flip = flip_y != 0;
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    return mpv_render_context_render(render_context->context, parameters);
}

void okmpv_render_report_swap(OKMPVRenderContext *render_context) {
    if (render_context != NULL && render_context->context != NULL) {
        mpv_render_context_report_swap(render_context->context);
    }
}

void okmpv_render_destroy(OKMPVRenderContext *render_context) {
    if (render_context == NULL) {
        return;
    }
    if (render_context->context != NULL) {
        mpv_render_context_set_update_callback(
            render_context->context,
            NULL,
            NULL
        );
        mpv_render_context_free(render_context->context);
        render_context->context = NULL;
    }
    free(render_context);
}
