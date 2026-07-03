#include "rtsp_demux.h"

#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavutil/opt.h>

struct RTSPDemux {
    char *url;
    atomic_int stop_flag;
};

/* libavformat calls this frequently while blocked; returning non-zero aborts the
 * current operation (connect or read) so stop() takes effect promptly even when a
 * TCP socket is stalled — this is what makes teardown clean and orphan-free. */
static int interrupt_cb(void *opaque) {
    RTSPDemux *d = (RTSPDemux *)opaque;
    return atomic_load(&d->stop_flag);
}

RTSPDemux *rtsp_demux_create(const char *url) {
    if (!url) return NULL;
    RTSPDemux *d = (RTSPDemux *)calloc(1, sizeof(RTSPDemux));
    if (!d) return NULL;
    d->url = strdup(url);
    if (!d->url) { free(d); return NULL; }
    atomic_init(&d->stop_flag, 0);
    avformat_network_init(); /* ref-counted; needed for RTSP/TLS */
    return d;
}

void rtsp_demux_stop(RTSPDemux *d) {
    if (d) atomic_store(&d->stop_flag, 1);
}

void rtsp_demux_free(RTSPDemux *d) {
    if (!d) return;
    free(d->url);
    free(d);
    avformat_network_deinit();
}

int rtsp_demux_run(RTSPDemux *d, rtsp_demux_data_cb on_data, void *userdata) {
    if (!d || !on_data) return -1;

    int ret = 0;
    AVFormatContext *fmt = avformat_alloc_context();
    if (!fmt) return AVERROR(ENOMEM);
    fmt->interrupt_callback.callback = interrupt_cb;
    fmt->interrupt_callback.opaque = d;

    /* Same low-latency demux options as the previous ffmpeg CLI invocation. */
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);   /* UDP-blocked cameras */
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    av_dict_set(&opts, "avioflags", "direct", 0);
    av_dict_set(&opts, "timeout", "5000000", 0);      /* 5s socket I/O timeout (us) */

    ret = avformat_open_input(&fmt, d->url, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) return ret; /* avformat_open_input frees fmt on failure */

    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) goto done;

    int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vidx < 0) { ret = vidx; goto done; }
    AVCodecParameters *par = fmt->streams[vidx]->codecpar;

    /* Reproduce the old `-bsf:v dump_extra=freq=keyframe` (SPS/PPS before every
     * keyframe). If the stream is AVCC (length-prefixed) rather than Annex-B,
     * prepend h264_mp4toannexb so H264Parser still sees start codes — matching
     * what the `-f h264` muxer would have done. */
    const char *chain =
        (par->codec_id == AV_CODEC_ID_H264 && par->extradata_size > 0 && par->extradata[0] == 1)
            ? "h264_mp4toannexb,dump_extra=freq=keyframe"
            : "dump_extra=freq=keyframe";

    AVBSFContext *bsf = NULL;
    ret = av_bsf_list_parse_str(chain, &bsf);
    if (ret < 0) goto done;
    ret = avcodec_parameters_copy(bsf->par_in, par);
    if (ret < 0) { av_bsf_free(&bsf); goto done; }
    ret = av_bsf_init(bsf);
    if (ret < 0) { av_bsf_free(&bsf); goto done; }

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) { av_bsf_free(&bsf); ret = AVERROR(ENOMEM); goto done; }

    while (!atomic_load(&d->stop_flag)) {
        ret = av_read_frame(fmt, pkt);
        if (ret < 0) break; /* EOF, error, or interrupted by stop */

        if (pkt->stream_index != vidx) {
            av_packet_unref(pkt);
            continue;
        }

        /* send consumes/moves the packet ref; receive refills pkt. */
        if (av_bsf_send_packet(bsf, pkt) == 0) {
            while (av_bsf_receive_packet(bsf, pkt) == 0) {
                if (pkt->size > 0) on_data(userdata, pkt->data, pkt->size);
                av_packet_unref(pkt);
            }
        } else {
            av_packet_unref(pkt);
        }
    }

    av_packet_free(&pkt);
    av_bsf_free(&bsf);

done:
    avformat_close_input(&fmt);
    /* A requested stop is a clean exit, not an error. */
    return atomic_load(&d->stop_flag) ? 0 : ret;
}
