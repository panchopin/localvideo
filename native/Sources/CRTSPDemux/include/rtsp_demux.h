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

/* Audio format codes reported by rtsp_demux_audio_cfg_cb. */
#define RTSP_AUDIO_NONE  0   /* no audio stream, or an unsupported codec */
#define RTSP_AUDIO_ALAW  1   /* G.711 A-law  (PCM alaw) */
#define RTSP_AUDIO_ULAW  2   /* G.711 mu-law (PCM ulaw) */
#define RTSP_AUDIO_AAC   3   /* AAC (asc = AudioSpecificConfig) */

/* Called ONCE on the demux thread right after the streams are probed, before any
 * packets — reports the audio format (RTSP_AUDIO_*), sample rate, channel count,
 * and (AAC only) the AudioSpecificConfig. `fmt == RTSP_AUDIO_NONE` means record
 * video only. */
typedef void (*rtsp_demux_audio_cfg_cb)(void *userdata, int fmt, int sample_rate,
                                        int channels, const uint8_t *asc, int asc_len);

/* Receives one raw audio packet (alaw/ulaw bytes, or an AAC frame) on the demux thread. */
typedef void (*rtsp_demux_audio_cb)(void *userdata, const uint8_t *data, int len);

/* Allocate a demuxer for `url` (copied internally). Returns NULL on failure.
 * Does not connect yet. */
RTSPDemux *rtsp_demux_create(const char *url);

/* Connect and read until stopped or the stream ends/errors. BLOCKS — call on a
 * background thread. Emits Annex-B video via `on_video`; if an audio stream is
 * present, reports it once via `on_audio_cfg` and streams packets via `on_audio`
 * (both may be NULL to ignore audio). Returns 0 on requested stop, <0 on error. */
int rtsp_demux_run(RTSPDemux *d,
                   rtsp_demux_data_cb on_video,
                   rtsp_demux_audio_cfg_cb on_audio_cfg,
                   rtsp_demux_audio_cb on_audio,
                   void *userdata);

/* Ask the run loop to stop; interrupts a blocked connect/read. Thread-safe. */
void rtsp_demux_stop(RTSPDemux *d);

/* Free the demuxer. Must not be called while rtsp_demux_run is executing. */
void rtsp_demux_free(RTSPDemux *d);

#endif /* RTSP_DEMUX_H */
