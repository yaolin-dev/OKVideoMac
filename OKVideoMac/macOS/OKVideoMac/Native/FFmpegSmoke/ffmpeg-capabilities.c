#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/hwcontext.h>

#include <stdio.h>

int main(void) {
    void *opaque = NULL;
    const AVCodec *codec = NULL;
    while ((codec = av_codec_iterate(&opaque)) != NULL) {
        const char *kind = av_codec_is_decoder(codec) ? "decoder" :
            (av_codec_is_encoder(codec) ? "encoder" : "codec");
        printf("%s|%s|%d\n", kind, codec->name, codec->type);
    }

    opaque = NULL;
    const AVInputFormat *input = NULL;
    while ((input = av_demuxer_iterate(&opaque)) != NULL) {
        printf("demuxer|%s\n", input->name);
    }

    opaque = NULL;
    const AVOutputFormat *output = NULL;
    while ((output = av_muxer_iterate(&opaque)) != NULL) {
        printf("muxer|%s\n", output->name);
    }

    opaque = NULL;
    const char *protocol = NULL;
    while ((protocol = avio_enum_protocols(&opaque, 0)) != NULL) {
        printf("protocol-in|%s\n", protocol);
    }
    opaque = NULL;
    while ((protocol = avio_enum_protocols(&opaque, 1)) != NULL) {
        printf("protocol-out|%s\n", protocol);
    }

    opaque = NULL;
    const AVFilter *filter = NULL;
    while ((filter = av_filter_iterate(&opaque)) != NULL) {
        printf("filter|%s\n", filter->name);
    }

    enum AVHWDeviceType device = AV_HWDEVICE_TYPE_NONE;
    while ((device = av_hwdevice_iterate_types(device)) != AV_HWDEVICE_TYPE_NONE) {
        printf("hwdevice|%s\n", av_hwdevice_get_type_name(device));
    }
    return 0;
}
