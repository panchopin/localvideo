#ifndef RTSP_DEMUX_H
#define RTSP_DEMUX_H

#include <stdint.h>

/*
 * In-process RTSP(S) demuxer (libavformat) — the credential-safe replacement for
 * spawning `ffmpeg` as a subprocess. The camera URL (which may embed a password)
 * lives only in this process's memory; it is NEVER placed in any process argv,
 * so it cannot leak via `ps`/pgrep/Activity Monitor.
 *
 * Behavior mirrors the previous CLI exactly:
 *   ffmpeg -rtsp_transport tcp -fflags nobuffer -flags low_delay -avioflags direct
 *          -i <url> -an -c:v copy -bsf:v dump_extra=freq=keyframe -f h264 -
 * i.e. demux only (no decode), emit Annex-B H.264 with SPS/PPS before keyframes.
 * The emitted bytes are byte-for-byte what the old stdout pipe delivered, so the
 * downstream H264Parser / VideoToolbox render path is unchanged.
 */

typedef struct RTSPDemux RTSPDemux;

/* Receives Annex-B H.264 bytes on the demux thread (same as `-f h264` stdout). */
typedef void (*rtsp_demux_data_cb)(void *userdata, const uint8_t *data, int len);

/* Allocate a demuxer for `url` (copied internally). Returns NULL on failure.
 * Does not connect yet. */
RTSPDemux *rtsp_demux_create(const char *url);

/* Connect and read until stopped or the stream ends/errors. BLOCKS — call on a
 * background thread. Emits Annex-B via `on_data`. Returns 0 on requested stop,
 * <0 on connect/read error. */
int rtsp_demux_run(RTSPDemux *d, rtsp_demux_data_cb on_data, void *userdata);

/* Ask the run loop to stop; interrupts a blocked connect/read. Thread-safe. */
void rtsp_demux_stop(RTSPDemux *d);

/* Free the demuxer. Must not be called while rtsp_demux_run is executing. */
void rtsp_demux_free(RTSPDemux *d);

#endif /* RTSP_DEMUX_H */
