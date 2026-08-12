#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

#include <stdio.h>
#include <string.h>

static int require_decoder(enum AVCodecID codec_id, const char *name) {
    if (avcodec_find_decoder(codec_id) == NULL) {
        fprintf(stderr, "missing decoder: %s\n", name);
        return 1;
    }
    return 0;
}

int main(void) {
    const char *configuration = avcodec_configuration();
    int failure = 0;
    avformat_network_init();
    failure |= require_decoder(AV_CODEC_ID_H264, "h264");
    failure |= require_decoder(AV_CODEC_ID_HEVC, "hevc");
    failure |= require_decoder(AV_CODEC_ID_AAC, "aac");
    if (strstr(configuration, "--enable-gpl") != NULL ||
        strstr(configuration, "--enable-nonfree") != NULL ||
        strstr(configuration, "--enable-version3") != NULL) {
        fprintf(stderr, "unexpected FFmpeg license-mode flag: %s\n", configuration);
        failure = 1;
    }
    if (strstr(configuration, "--enable-securetransport") == NULL ||
        strstr(configuration, "--enable-videotoolbox") == NULL ||
        strstr(configuration, "--enable-network") == NULL) {
        fprintf(stderr, "required FFmpeg capability flag is absent: %s\n", configuration);
        failure = 1;
    }
    if (failure != 0) {
        return 1;
    }
    printf("libavcodec=%u libavformat=%u license=%s\n",
           avcodec_version(), avformat_version(), avcodec_license());
    return 0;
}
