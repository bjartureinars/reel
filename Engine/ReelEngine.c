// See ReelEngine.h.
//
// How it works:
// - The film is split into segments of about SEGMENT_SECONDS that always start on a keyframe. Each segment can be
//   made from scratch after a seek and comes out the same as when played through, so HLS seeking just works.
// - Segment k holds everything from the first keyframe at or after boundary k up to the first at or after k + 1.
//   Boundaries come from the MKV/MP4 index when there is one, otherwise they are evenly spaced.
// - Decode times are the segment's own presentation times, sorted, minus a fixed delay. Blu-ray open GOPs and
//   MKV's missing decode times both come out right that way.
// - Times inside are microseconds from the start of the film.

#include "ReelEngine.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/avstring.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

#define SEGMENT_SECONDS 4
#define SEGMENT_US (SEGMENT_SECONDS * 1000000LL)
#define OUTPUT_SHIFT_US 1000000LL   // keeps every decode time positive
#define PREROLL_US 1500000LL        // sound is stored a little before its picture, and DTS needs a run-up
#define VIDEO_SCALE 90000
#define IO_BUFFER (256 * 1024)
#define PROBE_BYTES (24LL << 20)
#define SEGMENT_LIMIT (256LL << 20)

static const AVRational MICRO = {1, 1000000};

typedef struct {
    AVPacket *packet;
    int64_t time;
} Timed;

typedef struct {
    Timed *items;
    int count, capacity;
    int64_t bytes;
} Queue;

struct ReelMedia {
    ReelRead read;
    void *readContext;
    int64_t size, position;
    atomic_bool cancelled;

    AVFormatContext *input;
    AVIOContext *io;
    AVPacket *packet;
    int video, audio, subtitle;
    int64_t origin, duration;
    int64_t frame, delay;

    int64_t *starts;
    int count;

    // Where reading has got to
    int next;                // segment being gathered, -1 until the first seek
    int64_t segmentStart;    // its first keyframe, or AV_NOPTS_VALUE while looking for it
    int64_t lastTime;
    bool ended;
    Queue picture, sound;
    int64_t soundBytes;

    // Converting sound
    bool copyAudio;
    AVCodecContext *decoder, *encoder;
    AVAudioFifo *fifo;
    SwrContext *resampler;
    enum AVSampleFormat resampleFormat;
    AVChannelLayout resampleLayout;
    int resampleRate;
    AVFrame *decoded, *toEncode;
    int64_t fifoStart;       // sample number of the first sample waiting in the fifo
    int64_t soundUntil;

    AVCodecContext *subtitleDecoder;
    ReelCueHandler cueHandler;
    void *cueContext;

    // Dolby Vision profile 7 (UHD Blu-ray) is turned into profile 8.1, which Apple devices play.
    bool dolbyVision7;
};

static int dolby_vision_profile(const AVCodecParameters *par) {
    const AVPacketSideData *sd = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data,
                                                         AV_PKT_DATA_DOVI_CONF);
    return sd ? ((const AVDOVIDecoderConfigurationRecord *)sd->data)->dv_profile : 0;
}

/// A converter for one segment: segments are made alone after a seek, so each starts fresh.
static int open_dolby_vision(const AVStream *video, AVBSFContext **out) {
    const AVBitStreamFilter *filter = av_bsf_get_by_name("dovi_rpu");
    if (!filter) return AVERROR_BSF_NOT_FOUND;
    AVBSFContext *bsf = NULL;
    int result = av_bsf_alloc(filter, &bsf);
    if (result < 0) return result;
    if ((result = avcodec_parameters_copy(bsf->par_in, video->codecpar)) < 0) goto fail;
    bsf->time_base_in = video->time_base;
    if ((result = av_opt_set_int(bsf->priv_data, "to_p81", 1, 0)) < 0) goto fail;
    if ((result = av_opt_set_int(bsf->priv_data, "compression", 0, 0)) < 0) goto fail;
    if ((result = av_bsf_init(bsf)) < 0) goto fail;
    *out = bsf;
    return 0;
fail:
    av_bsf_free(&bsf);
    return result;
}

// MARK: Queues

static int queue_push(Queue *queue, const AVPacket *source, int64_t time) {
    if (queue->count == queue->capacity) {
        int capacity = queue->capacity ? queue->capacity * 2 : 256;
        Timed *items = realloc(queue->items, (size_t)capacity * sizeof(Timed));
        if (!items) return AVERROR(ENOMEM);
        queue->items = items;
        queue->capacity = capacity;
    }
    AVPacket *copy = av_packet_clone(source);
    if (!copy) return AVERROR(ENOMEM);
    queue->items[queue->count++] = (Timed){copy, time};
    queue->bytes += copy->size;
    return 0;
}

static void queue_drop(Queue *queue, int count) {
    for (int i = 0; i < count; i++) {
        queue->bytes -= queue->items[i].packet->size;
        av_packet_free(&queue->items[i].packet);
    }
    memmove(queue->items, queue->items + count, (size_t)(queue->count - count) * sizeof(Timed));
    queue->count -= count;
}

static void queue_clear(Queue *queue) {
    queue_drop(queue, queue->count);
}

// MARK: Reading

static int io_read(void *opaque, uint8_t *buffer, int size) {
    ReelMedia *m = opaque;
    if (atomic_load(&m->cancelled)) return AVERROR_EXIT;
    if (m->position >= m->size) return AVERROR_EOF;
    int wanted = (int)FFMIN((int64_t)size, m->size - m->position);
    int got = m->read(m->readContext, m->position, buffer, wanted);
    if (atomic_load(&m->cancelled)) return AVERROR_EXIT;
    if (got <= 0) return AVERROR(EIO);
    m->position += got;
    return got;
}

static int64_t io_seek(void *opaque, int64_t offset, int whence) {
    ReelMedia *m = opaque;
    whence &= ~AVSEEK_FORCE;
    int64_t target;
    switch (whence) {
        case AVSEEK_SIZE: return m->size;
        case SEEK_SET: target = offset; break;
        case SEEK_CUR: target = m->position + offset; break;
        case SEEK_END: target = m->size + offset; break;
        default: return AVERROR(EINVAL);
    }
    if (target < 0) return AVERROR(EINVAL);
    m->position = target;
    return target;
}

static int interrupted(void *opaque) {
    return atomic_load(&((ReelMedia *)opaque)->cancelled);
}

static int64_t film_time(const ReelMedia *m, int64_t timestamp, AVRational base) {
    return av_rescale_q(timestamp, base, MICRO) - m->origin;
}

// MARK: Opening

static bool can_copy_audio(const AVCodecParameters *par) {
    switch (par->codec_id) {
        case AV_CODEC_ID_AC3:
        case AV_CODEC_ID_EAC3:
            return true;
        case AV_CODEC_ID_AAC:   // ADTS has no header for the MP4 box, so that gets converted
        case AV_CODEC_ID_ALAC:
            return par->extradata_size > 0;
        default:
            return false;
    }
}

static bool is_lossless(const AVCodecParameters *par) {
    switch (par->codec_id) {
        case AV_CODEC_ID_DTS: return par->profile == AV_PROFILE_DTS_HD_MA || par->profile == AV_PROFILE_DTS_HD_MA_X
                                     || par->profile == AV_PROFILE_DTS_HD_MA_X_IMAX;
        case AV_CODEC_ID_TRUEHD:
        case AV_CODEC_ID_MLP:
        case AV_CODEC_ID_FLAC:
        case AV_CODEC_ID_ALAC:
            return true;
        default: {
            const AVCodecDescriptor *descriptor = avcodec_descriptor_get(par->codec_id);
            return descriptor && (descriptor->props & AV_CODEC_PROP_LOSSLESS) && !(descriptor->props & AV_CODEC_PROP_LOSSY);
        }
    }
}

static bool playable(const AVStream *stream) {
    const AVCodecParameters *par = stream->codecpar;
    if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
        return (par->codec_id == AV_CODEC_ID_H264 || par->codec_id == AV_CODEC_ID_HEVC) && par->width > 0
            && par->extradata_size > 0;
    }
    if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
        if (par->sample_rate <= 0 || par->ch_layout.nb_channels <= 0) return false;
        return can_copy_audio(par) || avcodec_find_decoder(par->codec_id) != NULL;
    }
    return par->codec_type == AVMEDIA_TYPE_SUBTITLE && avcodec_find_decoder(par->codec_id) != NULL;
}

static int plan_segments(ReelMedia *m) {
    AVStream *stream = m->input->streams[m->video];
    const char *format = m->input->iformat->name;
    bool indexed = strstr(format, "matroska") || strstr(format, "mov");
    if (indexed) {
        // MKV only reads its index on the first seek.
        int64_t middle = av_rescale_q(m->duration / 2 + m->origin, MICRO, stream->time_base);
        av_seek_frame(m->input, m->video, middle, AVSEEK_FLAG_BACKWARD);
        if (atomic_load(&m->cancelled)) return AVERROR_EXIT;
        int entries = avformat_index_get_entries_count(stream);
        int64_t last = 0;
        if (entries > 1) last = film_time(m, avformat_index_get_entry(stream, entries - 1)->timestamp, stream->time_base);
        if (entries > 1 && last > m->duration - FFMAX(60000000LL, m->duration / 20)) {
            m->starts = malloc((size_t)(entries + 2) * sizeof(int64_t));
            if (!m->starts) return AVERROR(ENOMEM);
            int count = 0;
            m->starts[count++] = 0;
            for (int i = 0; i < entries; i++) {
                const AVIndexEntry *entry = avformat_index_get_entry(stream, i);
                if (!(entry->flags & AVINDEX_KEYFRAME)) continue;
                int64_t time = film_time(m, entry->timestamp, stream->time_base);
                if (time >= m->starts[count - 1] + SEGMENT_US && time < m->duration - 1000000) m->starts[count++] = time;
            }
            m->starts[count] = m->duration;
            m->count = count;
            return 0;
        }
    }
    int count = (int)FFMAX(1, (m->duration - 1000000) / SEGMENT_US + 1);
    m->starts = malloc((size_t)(count + 1) * sizeof(int64_t));
    if (!m->starts) return AVERROR(ENOMEM);
    for (int i = 0; i < count; i++) m->starts[i] = i * SEGMENT_US;
    m->starts[count] = m->duration;
    m->count = count;
    return 0;
}

ReelMedia *reel_open(ReelRead read, void *context, int64_t size, int *error) {
    int result = AVERROR(ENOMEM);
    ReelMedia *m = calloc(1, sizeof(*m));
    if (!m) goto fail;
    m->read = read;
    m->readContext = context;
    m->size = size;
    m->video = m->audio = m->subtitle = m->next = -1;
    m->segmentStart = AV_NOPTS_VALUE;
    m->fifoStart = AV_NOPTS_VALUE;
    m->resampleFormat = AV_SAMPLE_FMT_NONE;
    atomic_init(&m->cancelled, false);

    av_log_set_level(AV_LOG_FATAL);
    m->packet = av_packet_alloc();
    m->decoded = av_frame_alloc();
    m->toEncode = av_frame_alloc();
    m->input = avformat_alloc_context();
    uint8_t *buffer = av_malloc(IO_BUFFER);
    if (!m->packet || !m->decoded || !m->toEncode || !m->input || !buffer) {
        av_free(buffer);
        goto fail;
    }
    m->io = avio_alloc_context(buffer, IO_BUFFER, 0, m, io_read, NULL, io_seek);
    if (!m->io) {
        av_free(buffer);
        goto fail;
    }
    m->io->seekable = AVIO_SEEKABLE_NORMAL;
    m->input->pb = m->io;
    m->input->flags |= AVFMT_FLAG_CUSTOM_IO;
    m->input->interrupt_callback = (AVIOInterruptCB){interrupted, m};
    m->input->probesize = PROBE_BYTES;
    // Long enough to see every sound track. Waiting for every subtitle track would read hundreds of MB.
    m->input->max_analyze_duration = 5000000;

    if ((result = avformat_open_input(&m->input, NULL, NULL, NULL)) < 0) goto fail;
    if ((result = avformat_find_stream_info(m->input, NULL)) < 0) goto fail;

    result = AVERROR_STREAM_NOT_FOUND;
    for (unsigned i = 0; i < m->input->nb_streams; i++) {
        AVStream *stream = m->input->streams[i];
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO || (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        if (playable(stream)) {
            m->video = (int)i;
            break;
        }
    }
    if (m->video < 0) goto fail;

    AVStream *video = m->input->streams[m->video];
    m->dolbyVision7 = video->codecpar->codec_id == AV_CODEC_ID_HEVC
        && dolby_vision_profile(video->codecpar) == 7 && av_bsf_get_by_name("dovi_rpu");
    if (video->start_time != AV_NOPTS_VALUE) m->origin = av_rescale_q(video->start_time, video->time_base, MICRO);
    else if (m->input->start_time != AV_NOPTS_VALUE) m->origin = m->input->start_time;

    result = AVERROR_INVALIDDATA;
    if (m->input->duration != AV_NOPTS_VALUE && m->input->duration > 0) m->duration = m->input->duration;
    else if (video->duration != AV_NOPTS_VALUE) m->duration = av_rescale_q(video->duration, video->time_base, MICRO);
    if (m->duration <= 0) goto fail;

    AVRational rate = av_guess_frame_rate(m->input, video, NULL);
    m->frame = rate.num > 0 && rate.den > 0 ? av_rescale(1000000, rate.den, rate.num) : 41708;
    m->delay = FFMAX(video->codecpar->video_delay, 5) * m->frame;

    if ((result = plan_segments(m)) < 0) goto fail;
    if (error) *error = 0;
    return m;

fail:
    if (error) *error = result;
    reel_close(m);
    return NULL;
}

void reel_cancel(ReelMedia *m) {
    if (m) atomic_store(&m->cancelled, true);
}

static void close_selection(ReelMedia *m) {
    avcodec_free_context(&m->decoder);
    avcodec_free_context(&m->encoder);
    avcodec_free_context(&m->subtitleDecoder);
    swr_free(&m->resampler);
    av_channel_layout_uninit(&m->resampleLayout);
    m->resampleFormat = AV_SAMPLE_FMT_NONE;
    if (m->fifo) av_audio_fifo_free(m->fifo);
    m->fifo = NULL;
    m->audio = m->subtitle = -1;
    m->copyAudio = false;
}

void reel_close(ReelMedia *m) {
    if (!m) return;
    close_selection(m);
    queue_clear(&m->picture);
    queue_clear(&m->sound);
    free(m->picture.items);
    free(m->sound.items);
    free(m->starts);
    avformat_close_input(&m->input);
    if (m->io) {
        av_freep(&m->io->buffer);
        avio_context_free(&m->io);
    }
    av_packet_free(&m->packet);
    av_frame_free(&m->decoded);
    av_frame_free(&m->toEncode);
    free(m);
}

double reel_duration(const ReelMedia *m) {
    return (double)m->duration / 1e6;
}

int reel_stream_count(const ReelMedia *m) {
    return (int)m->input->nb_streams;
}

static void copy_text(char *out, size_t size, const char *text) {
    snprintf(out, size, "%s", text ? text : "");
}

bool reel_stream(const ReelMedia *m, int position, ReelStream *out) {
    memset(out, 0, sizeof(*out));
    if (position < 0 || position >= (int)m->input->nb_streams) return false;
    AVStream *stream = m->input->streams[position];
    const AVCodecParameters *par = stream->codecpar;
    switch (par->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            if (position != m->video) return false;
            out->kind = ReelKindVideo;
            break;
        case AVMEDIA_TYPE_AUDIO: out->kind = ReelKindAudio; break;
        case AVMEDIA_TYPE_SUBTITLE: out->kind = ReelKindSubtitle; break;
        default: return false;
    }
    out->index = position;
    out->pid = strstr(m->input->iformat->name, "mpegts") ? stream->id : 0;
    copy_text(out->codec, sizeof(out->codec), avcodec_get_name(par->codec_id));
    copy_text(out->profile, sizeof(out->profile), avcodec_profile_name(par->codec_id, par->profile));
    const AVDictionaryEntry *language = av_dict_get(stream->metadata, "language", NULL, 0);
    const AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
    copy_text(out->language, sizeof(out->language), language ? language->value : NULL);
    copy_text(out->title, sizeof(out->title), title ? title->value : NULL);
    out->width = par->width;
    out->height = par->height;
    out->channels = par->ch_layout.nb_channels;
    out->isDefault = stream->disposition & AV_DISPOSITION_DEFAULT;
    out->isForced = stream->disposition & AV_DISPOSITION_FORCED;
    out->isCommentary = (stream->disposition & AV_DISPOSITION_COMMENT) || (title && av_stristr(title->value, "commentary"));
    out->playable = playable(stream);
    if (out->kind == ReelKindVideo) {
        out->untouched = out->lossless = true;
        out->frameRate = 1e6 / (double)m->frame;
        if (par->color_trc == AVCOL_TRC_SMPTE2084) out->range = ReelRangePQ;
        else if (par->color_trc == AVCOL_TRC_ARIB_STD_B67) out->range = ReelRangeHLG;
        int profile = dolby_vision_profile(par);
        // What plays: profile 7 becomes 8.1; other profiles Apple devices can't play are left as HDR10.
        out->dolbyVision = profile == 7 && m->dolbyVision7 ? 8 : (profile == 5 || profile == 8) ? profile : 0;
    } else if (out->kind == ReelKindAudio) {
        out->untouched = can_copy_audio(par);
        // Seven or eight channels are folded down to 5.1, so those don't stay lossless.
        out->lossless = is_lossless(par) && (out->untouched || par->ch_layout.nb_channels <= 6);
    }
    return true;
}

// MARK: Choosing tracks

static int open_converter(ReelMedia *m, AVStream *stream) {
    const AVCodecParameters *par = stream->codecpar;
    const AVCodec *from = avcodec_find_decoder(par->codec_id);
    const AVCodec *to = avcodec_find_encoder(AV_CODEC_ID_ALAC);
    if (!from || !to) return AVERROR_DECODER_NOT_FOUND;
    int result;
    if (!(m->decoder = avcodec_alloc_context3(from))) return AVERROR(ENOMEM);
    if ((result = avcodec_parameters_to_context(m->decoder, par)) < 0) return result;
    m->decoder->pkt_timebase = stream->time_base;
    if ((result = avcodec_open2(m->decoder, from, NULL)) < 0) return result;

    if (!(m->encoder = avcodec_alloc_context3(to))) return AVERROR(ENOMEM);
    AVChannelLayout layout;
    int channels = par->ch_layout.nb_channels;
    switch (channels) {
        case 1: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO; break;
        case 2: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO; break;
        case 3: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_SURROUND; break;
        case 4: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_4POINT0; break;
        case 5: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT0_BACK; break;
        default: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1_BACK; break;
    }
    if ((result = av_channel_layout_copy(&m->encoder->ch_layout, &layout)) < 0) return result;
    bool sixteen = par->bits_per_raw_sample == 16
        || (par->bits_per_raw_sample == 0 && (par->format == AV_SAMPLE_FMT_S16 || par->format == AV_SAMPLE_FMT_S16P));
    m->encoder->sample_fmt = sixteen ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S32P;
    m->encoder->bits_per_raw_sample = sixteen ? 16 : 24;
    m->encoder->sample_rate = par->sample_rate;
    m->encoder->time_base = (AVRational){1, par->sample_rate};
    m->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    m->encoder->compression_level = 1;
    if ((result = avcodec_open2(m->encoder, to, NULL)) < 0) return result;
    m->fifo = av_audio_fifo_alloc(m->encoder->sample_fmt, m->encoder->ch_layout.nb_channels, par->sample_rate);
    return m->fifo ? 0 : AVERROR(ENOMEM);
}

int reel_select(ReelMedia *m, int audio, int subtitle, ReelCueHandler handler, void *context) {
    close_selection(m);
    m->next = -1;
    m->cueHandler = handler;
    m->cueContext = context;
    int streams = (int)m->input->nb_streams, result;
    if (audio >= 0) {
        if (audio >= streams) return AVERROR(EINVAL);
        AVStream *stream = m->input->streams[audio];
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO || !playable(stream)) return AVERROR(EINVAL);
        m->copyAudio = can_copy_audio(stream->codecpar);
        if (!m->copyAudio && (result = open_converter(m, stream)) < 0) {
            close_selection(m);
            return result;
        }
        m->audio = audio;
    }
    if (subtitle >= 0) {
        if (subtitle >= streams) return AVERROR(EINVAL);
        AVStream *stream = m->input->streams[subtitle];
        const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE || !codec) return AVERROR(EINVAL);
        if (!(m->subtitleDecoder = avcodec_alloc_context3(codec))) return AVERROR(ENOMEM);
        if ((result = avcodec_parameters_to_context(m->subtitleDecoder, stream->codecpar)) < 0) return result;
        m->subtitleDecoder->pkt_timebase = stream->time_base;
        if ((result = avcodec_open2(m->subtitleDecoder, codec, NULL)) < 0) return result;
        m->subtitle = subtitle;
    }
    for (int i = 0; i < streams; i++) {
        bool wanted = i == m->video || i == m->audio || i == m->subtitle;
        m->input->streams[i]->discard = wanted ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }
    return 0;
}

int reel_segment_count(const ReelMedia *m) {
    return m->count;
}

double reel_segment_duration(const ReelMedia *m, int segment) {
    if (segment < 0 || segment >= m->count) return 0;
    return (double)(m->starts[segment + 1] - m->starts[segment]) / 1e6;
}

// MARK: Sound

static int encoder_output(ReelMedia *m) {
    AVPacket *packet = av_packet_alloc();
    if (!packet) return AVERROR(ENOMEM);
    int result;
    while ((result = avcodec_receive_packet(m->encoder, packet)) >= 0) {
        int64_t time = av_rescale_q(packet->pts, m->encoder->time_base, MICRO);
        result = queue_push(&m->sound, packet, time);
        av_packet_unref(packet);
        if (result < 0) break;
    }
    av_packet_free(&packet);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static int encode_waiting(ReelMedia *m, bool all) {
    int frameSize = m->encoder->frame_size, result;
    for (;;) {
        int waiting = av_audio_fifo_size(m->fifo);
        if (waiting == 0 || (waiting < frameSize && !all)) return 0;
        int count = FFMIN(waiting, frameSize);
        AVFrame *frame = m->toEncode;
        av_frame_unref(frame);
        frame->nb_samples = count;
        frame->format = m->encoder->sample_fmt;
        frame->sample_rate = m->encoder->sample_rate;
        if ((result = av_channel_layout_copy(&frame->ch_layout, &m->encoder->ch_layout)) < 0) return result;
        if ((result = av_frame_get_buffer(frame, 0)) < 0) return result;
        if (av_audio_fifo_read(m->fifo, (void **)frame->data, count) < count) return AVERROR(EIO);
        frame->pts = m->fifoStart;
        m->fifoStart += count;
        m->soundUntil = av_rescale(m->fifoStart, 1000000, m->encoder->sample_rate);
        if ((result = avcodec_send_frame(m->encoder, frame)) < 0) return result;
        if ((result = encoder_output(m)) < 0) return result;
    }
}

static int convert_frame(ReelMedia *m, AVFrame *frame) {
    AVCodecContext *encoder = m->encoder;
    int result;
    if (frame->pts != AV_NOPTS_VALUE) {
        int64_t time = film_time(m, frame->pts, m->input->streams[m->audio]->time_base);
        int64_t sample = av_rescale(time, encoder->sample_rate, 1000000);
        int waiting = av_audio_fifo_size(m->fifo);
        if (m->fifoStart == AV_NOPTS_VALUE) {
            m->fifoStart = sample;
        } else if (sample > m->fifoStart + waiting + encoder->sample_rate / 20) {
            // A real hole. MKV's millisecond rounding never gets this far.
            if ((result = encode_waiting(m, true)) < 0) return result;
            m->fifoStart = sample;
        }
    } else if (m->fifoStart == AV_NOPTS_VALUE) {
        return 0;
    }

    int channels = encoder->ch_layout.nb_channels;
    AVChannelLayout input = {0};
    // With the same number of channels they're in the same order (5.1 side and 5.1 back differ only in name),
    // so relabel them rather than mix.
    const AVChannelLayout *from = frame->ch_layout.nb_channels == channels ? &encoder->ch_layout : &frame->ch_layout;
    if ((result = av_channel_layout_copy(&input, from)) < 0) return result;
    if (!m->resampler || m->resampleFormat != frame->format || m->resampleRate != frame->sample_rate
        || av_channel_layout_compare(&m->resampleLayout, &input) != 0) {
        swr_free(&m->resampler);
        result = swr_alloc_set_opts2(&m->resampler, &encoder->ch_layout, encoder->sample_fmt, encoder->sample_rate,
                                     &input, frame->format, frame->sample_rate, 0, NULL);
        if (result >= 0) result = swr_init(m->resampler);
        if (result >= 0) result = av_channel_layout_copy(&m->resampleLayout, &input);
        if (result < 0) {
            swr_free(&m->resampler);
            av_channel_layout_uninit(&input);
            return result;
        }
        m->resampleFormat = frame->format;
        m->resampleRate = frame->sample_rate;
    }
    av_channel_layout_uninit(&input);

    int room = swr_get_out_samples(m->resampler, frame->nb_samples);
    uint8_t *out[AV_NUM_DATA_POINTERS] = {0};
    if ((result = av_samples_alloc(out, NULL, channels, FFMAX(room, 1), encoder->sample_fmt, 0)) < 0) return result;
    result = swr_convert(m->resampler, out, room, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (result > 0 && av_audio_fifo_write(m->fifo, (void **)out, result) < result) result = AVERROR(ENOMEM);
    av_freep(&out[0]);
    if (result < 0) return result;
    return encode_waiting(m, false);
}

static int take_sound(ReelMedia *m, AVPacket *packet) {
    int result;
    if (m->copyAudio) {
        if (!packet) return 0;
        int64_t stamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
        if (stamp == AV_NOPTS_VALUE) return 0;
        AVRational base = m->input->streams[m->audio]->time_base;
        int64_t time = film_time(m, stamp, base);
        if ((result = queue_push(&m->sound, packet, time)) < 0) return result;
        m->soundUntil = time + av_rescale_q(FFMAX(packet->duration, 1), base, MICRO);
        return 0;
    }
    if (packet) m->soundBytes += packet->size;
    result = avcodec_send_packet(m->decoder, packet);
    // After a seek the first packet or two can be unreadable, and a damaged one is no reason to stop.
    if (result < 0) return result == AVERROR(ENOMEM) ? result : 0;
    for (;;) {
        result = avcodec_receive_frame(m->decoder, m->decoded);
        if (result < 0) return result == AVERROR(ENOMEM) ? result : 0;
        result = convert_frame(m, m->decoded);
        av_frame_unref(m->decoded);
        if (result < 0) return result;
    }
}

// MARK: Subtitles

static int take_subtitle(ReelMedia *m, AVPacket *packet) {
    if (!m->cueHandler || !m->subtitleDecoder) return 0;
    AVSubtitle decoded = {0};
    int found = 0;
    if (avcodec_decode_subtitle2(m->subtitleDecoder, &decoded, &found, packet) < 0 || !found) return 0;

    AVRational base = m->input->streams[m->subtitle]->time_base;
    int64_t start;
    if (decoded.pts != AV_NOPTS_VALUE) start = decoded.pts - m->origin;
    else if (packet->pts != AV_NOPTS_VALUE) start = film_time(m, packet->pts, base);
    else {
        avsubtitle_free(&decoded);
        return 0;
    }
    start += (int64_t)decoded.start_display_time * 1000;

    ReelCue cue = {0};
    cue.start = (double)start / 1e6;
    cue.end = -1;
    if (decoded.end_display_time != 0 && decoded.end_display_time != UINT32_MAX) {
        cue.end = cue.start + (double)(decoded.end_display_time - decoded.start_display_time) / 1e3;
    } else if (packet->duration > 0) {
        cue.end = cue.start + (double)av_rescale_q(packet->duration, base, MICRO) / 1e6;
    }
    cue.canvasWidth = m->subtitleDecoder->width > 0 ? m->subtitleDecoder->width : 1920;
    cue.canvasHeight = m->subtitleDecoder->height > 0 ? m->subtitleDecoder->height : 1080;

    int sent = 0;
    for (unsigned i = 0; i < decoded.num_rects; i++) {
        const AVSubtitleRect *rect = decoded.rects[i];
        ReelCue each = cue;
        each.continues = sent > 0;
        if (rect->type == SUBTITLE_BITMAP && rect->w > 0 && rect->h > 0 && rect->w <= 4096 && rect->h <= 4096) {
            uint8_t *rgba = malloc((size_t)rect->w * (size_t)rect->h * 4);
            if (!rgba) break;
            const uint32_t *palette = (const uint32_t *)rect->data[1];
            for (int y = 0; y < rect->h; y++) {
                const uint8_t *source = rect->data[0] + y * rect->linesize[0];
                uint8_t *target = rgba + y * rect->w * 4;
                for (int x = 0; x < rect->w; x++, target += 4) {
                    uint32_t color = palette[source[x]];
                    target[0] = color >> 16;
                    target[1] = color >> 8;
                    target[2] = color;
                    target[3] = color >> 24;
                }
            }
            each.x = rect->x;
            each.y = rect->y;
            each.width = rect->w;
            each.height = rect->h;
            each.rgba = rgba;
            m->cueHandler(m->cueContext, &each);
            free(rgba);
            sent++;
        } else if (rect->type == SUBTITLE_TEXT && rect->text) {
            each.text = rect->text;
            m->cueHandler(m->cueContext, &each);
            sent++;
        } else if (rect->type == SUBTITLE_ASS && rect->ass) {
            // "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
            const char *text = rect->ass;
            for (int commas = 0; commas < 8 && text; commas++) {
                text = strchr(text, ',');
                if (text) text++;
            }
            if (text) {
                each.text = text;
                m->cueHandler(m->cueContext, &each);
                sent++;
            }
        }
    }
    if (!sent) m->cueHandler(m->cueContext, &cue);
    avsubtitle_free(&decoded);
    return 0;
}

// MARK: Moving through the film

static void forget_position(ReelMedia *m) {
    queue_clear(&m->picture);
    queue_clear(&m->sound);
    m->soundBytes = 0;
    m->ended = false;
    m->segmentStart = AV_NOPTS_VALUE;
    m->lastTime = AV_NOPTS_VALUE;
    m->fifoStart = AV_NOPTS_VALUE;
    m->soundUntil = INT64_MIN;
    if (m->decoder) avcodec_flush_buffers(m->decoder);
    if (m->subtitleDecoder) avcodec_flush_buffers(m->subtitleDecoder);
    if (m->fifo) av_audio_fifo_reset(m->fifo);
    swr_free(&m->resampler);
}

static int seek_to(ReelMedia *m, int64_t time) {
    AVStream *video = m->input->streams[m->video];
    int64_t wanted = FFMAX(time, 0) + m->origin;
    int64_t stamp = av_rescale_q(wanted, MICRO, video->time_base);
    int result = av_seek_frame(m->input, m->video, stamp, AVSEEK_FLAG_BACKWARD);
    if (result < 0 && time <= 0 && !atomic_load(&m->cancelled)) result = avformat_seek_file(m->input, -1, INT64_MIN, 0, INT64_MAX, 0);
    return result < 0 ? result : 0;
}

static void drain_sound(ReelMedia *m) {
    if (m->audio < 0 || m->copyAudio) return;
    take_sound(m, NULL);
    encode_waiting(m, true);
}

/// Reads until segment m->next is whole. *cut is how many queued pictures are in it, *end where it ends.
static int gather(ReelMedia *m, int *cut, int64_t *end) {
    const int64_t slack = 1000;
    int k = m->next, result;
    bool haveEnd = false;
    int afterEnd = 0;

    // The keyframe ending the last segment is already queued.
    for (;;) {
        if (haveEnd) {
            bool soundReady = m->audio < 0 || m->soundUntil >= *end;
            // Give up on sound that stops early, rather than reading to the end of the film for it.
            if (soundReady || m->ended || afterEnd > 120) return 0;
        } else if (m->ended) {
            if (m->segmentStart == AV_NOPTS_VALUE || m->picture.count == 0) return AVERROR_EOF;
            *cut = m->picture.count;
            *end = FFMAX(m->duration, m->lastTime + m->frame);
            return 0;
        }
        if (atomic_load(&m->cancelled)) return AVERROR_EXIT;
        if (m->picture.bytes > SEGMENT_LIMIT) return AVERROR(E2BIG);

        result = av_read_frame(m->input, m->packet);
        if (result == AVERROR_EOF) {
            drain_sound(m);
            m->ended = true;
            continue;
        }
        if (result < 0) return result;

        AVPacket *packet = m->packet;
        AVStream *stream = m->input->streams[packet->stream_index];
        result = 0;
        if (packet->stream_index == m->video) {
            int64_t stamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
            bool keep = true;
            int64_t time;
            if (stamp != AV_NOPTS_VALUE) time = film_time(m, stamp, stream->time_base);
            else if (m->lastTime != AV_NOPTS_VALUE) time = m->lastTime + m->frame;
            else time = AV_NOPTS_VALUE, keep = false;

            if (keep) {
                bool key = packet->flags & AV_PKT_FLAG_KEY;
                m->lastTime = time;
                if (m->segmentStart == AV_NOPTS_VALUE) {
                    if (key && (k == 0 || time >= m->starts[k] - slack)) m->segmentStart = time;
                    else keep = false;
                }
                if (keep) {
                    if (haveEnd) {
                        afterEnd++;
                    } else if (key && k + 1 < m->count && m->picture.count > 0 && time >= m->starts[k + 1] - slack) {
                        haveEnd = true;
                        *cut = m->picture.count;
                        *end = time;
                    }
                    result = queue_push(&m->picture, packet, time);
                }
            }
        } else if (packet->stream_index == m->audio) {
            result = take_sound(m, packet);
        } else if (packet->stream_index == m->subtitle) {
            result = take_subtitle(m, packet);
        }
        av_packet_unref(packet);
        if (result < 0) return result;
    }
}

// MARK: Writing segments

static int compare_times(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}

static int duplicate(const uint8_t *source, int size, uint8_t **out) {
    if (!(*out = malloc((size_t)FFMAX(size, 1)))) return AVERROR(ENOMEM);
    memcpy(*out, source, (size_t)size);
    return 0;
}

static int write_segment(ReelMedia *m, int segment, int cut, int64_t from, int64_t to,
                         uint8_t **init, int *initSize, uint8_t **data, int *dataSize, int64_t *sourceBytes) {
    AVFormatContext *output = NULL;
    AVDictionary *options = NULL;
    AVPacket *packet = NULL;
    AVBSFContext *dolbyVision = NULL;
    uint8_t *whole = NULL;
    int64_t *order = NULL;
    int64_t bytes = 0;
    int result = avformat_alloc_output_context2(&output, NULL, "mp4", NULL);
    if (result < 0) return result;
    if ((result = avio_open_dyn_buf(&output->pb)) < 0) goto done;
    output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    output->max_interleave_delta = 0;

    const AVStream *videoIn = m->input->streams[m->video];
    AVStream *videoOut = avformat_new_stream(output, NULL);
    if (!videoOut) { result = AVERROR(ENOMEM); goto done; }
    if (m->dolbyVision7) {
        if ((result = open_dolby_vision(videoIn, &dolbyVision)) < 0) goto done;
        // The converter's output says profile 8.1, which goes in the 'dvvC' box.
        if ((result = avcodec_parameters_copy(videoOut->codecpar, dolbyVision->par_out)) < 0) goto done;
        output->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
    } else {
        if ((result = avcodec_parameters_copy(videoOut->codecpar, videoIn->codecpar)) < 0) goto done;
        int profile = dolby_vision_profile(videoIn->codecpar);
        if (profile == 5 || profile == 8) output->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
        else av_packet_side_data_remove(videoOut->codecpar->coded_side_data, &videoOut->codecpar->nb_coded_side_data,
                                        AV_PKT_DATA_DOVI_CONF);
    }
    // 'hvc1' with a 'dvvC' box is how Apple wants profile 8.1: HDR10 for anything that can't show Dolby Vision.
    videoOut->codecpar->codec_tag = videoIn->codecpar->codec_id == AV_CODEC_ID_HEVC
        ? MKTAG('h', 'v', 'c', '1') : MKTAG('a', 'v', 'c', '1');
    // Profile 5 has no HDR10 picture to fall back on, so it's marked as Dolby Vision only.
    if (!m->dolbyVision7 && dolby_vision_profile(videoIn->codecpar) == 5) videoOut->codecpar->codec_tag = MKTAG('d', 'v', 'h', '1');
    videoOut->time_base = (AVRational){1, VIDEO_SCALE};

    AVStream *audioOut = NULL;
    if (m->audio >= 0) {
        if (!(audioOut = avformat_new_stream(output, NULL))) { result = AVERROR(ENOMEM); goto done; }
        if (m->copyAudio) result = avcodec_parameters_copy(audioOut->codecpar, m->input->streams[m->audio]->codecpar);
        else result = avcodec_parameters_from_context(audioOut->codecpar, m->encoder);
        if (result < 0) goto done;
        audioOut->codecpar->codec_tag = 0;
        audioOut->time_base = (AVRational){1, audioOut->codecpar->sample_rate};
    }

    av_dict_set(&options, "movflags", "empty_moov+delay_moov+default_base_moof+frag_custom+frag_discont+skip_trailer", 0);
    av_dict_set(&options, "use_editlist", "0", 0);
    av_dict_set_int(&options, "fragment_index", segment + 1, 0);
    av_dict_set_int(&options, "video_track_timescale", VIDEO_SCALE, 0);
    if ((result = avformat_write_header(output, &options)) < 0) goto done;

    order = malloc((size_t)cut * sizeof(int64_t));
    packet = av_packet_alloc();
    if (!order || !packet) { result = AVERROR(ENOMEM); goto done; }
    for (int i = 0; i < cut; i++) order[i] = m->picture.items[i].time;
    qsort(order, (size_t)cut, sizeof(int64_t), compare_times);

    int64_t shift = OUTPUT_SHIFT_US, previous = INT64_MIN;
    for (int i = 0; i < cut; i++) {
        if ((result = av_packet_ref(packet, m->picture.items[i].packet)) < 0) goto done;
        bytes += packet->size;
        if (dolbyVision) {
            // One packet in, one out: only the Dolby Vision parts of it change.
            if ((result = av_bsf_send_packet(dolbyVision, packet)) < 0) goto done;
            if ((result = av_bsf_receive_packet(dolbyVision, packet)) < 0) goto done;
        }
        int64_t pts = av_rescale_q(m->picture.items[i].time + shift, MICRO, videoOut->time_base);
        int64_t dts = av_rescale_q(FFMAX(order[i] + shift - m->delay, 0), MICRO, videoOut->time_base);
        if (previous != INT64_MIN && dts <= previous) dts = previous + 1;
        int64_t step = i + 1 < cut ? order[i + 1] - order[i] : m->frame;
        packet->pts = FFMAX(pts, dts);
        packet->dts = previous = dts;
        packet->duration = av_rescale_q(FFMAX(step, 1), MICRO, videoOut->time_base);
        packet->stream_index = videoOut->index;
        packet->pos = -1;
        packet->time_base = videoOut->time_base;
        result = av_write_frame(output, packet);
        av_packet_unref(packet);
        if (result < 0) goto done;
    }

    if (audioOut) {
        AVRational base = m->copyAudio ? m->input->streams[m->audio]->time_base : m->encoder->time_base;
        previous = INT64_MIN;
        for (int i = 0; i < m->sound.count; i++) {
            const Timed *item = &m->sound.items[i];
            if (item->time < from || item->time >= to) continue;
            if ((result = av_packet_ref(packet, item->packet)) < 0) goto done;
            if (m->copyAudio) bytes += packet->size;
            int64_t dts = FFMAX(av_rescale_q(item->time + shift, MICRO, audioOut->time_base), 0);
            if (previous != INT64_MIN && dts <= previous) dts = previous + 1;
            packet->pts = packet->dts = previous = dts;
            packet->duration = av_rescale_q(packet->duration, base, audioOut->time_base);
            packet->stream_index = audioOut->index;
            packet->pos = -1;
            packet->time_base = audioOut->time_base;
            result = av_write_frame(output, packet);
            av_packet_unref(packet);
            if (result < 0) goto done;
        }
    }

    // With delay_moov the first flush writes the header and the second the fragment.
    if ((result = av_write_frame(output, NULL)) < 0) goto done;
    if ((result = av_write_frame(output, NULL)) < 0) goto done;
    avio_flush(output->pb);
    int size = avio_close_dyn_buf(output->pb, &whole);
    output->pb = NULL;

    int split = -1;
    for (int64_t at = 0; at + 8 <= size;) {
        uint32_t box = AV_RB32(whole + at);
        if (!memcmp(whole + at + 4, "moof", 4) || !memcmp(whole + at + 4, "styp", 4)) {
            split = (int)at;
            break;
        }
        if (box < 8) break;
        at += box;
    }
    if (split <= 0) { result = AVERROR_INVALIDDATA; goto done; }
    if (init) {
        if ((result = duplicate(whole, split, init)) < 0) goto done;
        *initSize = split;
    }
    if ((result = duplicate(whole + split, size - split, data)) < 0) {
        if (init) {
            free(*init);
            *init = NULL;
        }
        goto done;
    }
    *dataSize = size - split;
    *sourceBytes = bytes;

done:
    if (output && output->pb) {
        uint8_t *unused = NULL;
        avio_close_dyn_buf(output->pb, &unused);
        av_free(unused);
        output->pb = NULL;
    }
    av_free(whole);
    free(order);
    av_packet_free(&packet);
    av_bsf_free(&dolbyVision);
    av_dict_free(&options);
    avformat_free_context(output);
    return result < 0 ? result : 0;
}

int reel_segment(ReelMedia *m, int segment, uint8_t **init, int *initSize,
                 uint8_t **data, int *dataSize, ReelSegmentInfo *info) {
    if (init) *init = NULL;
    *data = NULL;
    if (segment < 0 || segment >= m->count) return AVERROR(EINVAL);

    int result = 0, cut = 0;
    int64_t end = 0;
    bool continuing = m->next == segment;
    if (!continuing) {
        // A failed seek mustn't look like a finished one.
        m->next = -1;
        forget_position(m);
        if ((result = seek_to(m, m->starts[segment] - PREROLL_US)) < 0) return result;
        m->next = segment;
    }
    for (int attempt = 0;; attempt++) {
        result = gather(m, &cut, &end);
        if (result < 0) break;
        // Without an index a seek can land past the keyframe it was aimed at. Go back further.
        bool late = !continuing && segment > 0 && m->segmentStart > m->starts[segment] + 2 * SEGMENT_US;
        if (!late || attempt >= 2) break;
        forget_position(m);
        if ((result = seek_to(m, m->starts[segment] - PREROLL_US - (attempt + 1) * 5000000LL)) < 0) break;
    }
    if (result < 0) {
        m->next = -1;
        return result;
    }

    // Open GOPs put a few pictures before the keyframe, so sound is cut at the keyframes themselves.
    int64_t from = segment == 0 ? INT64_MIN : m->segmentStart;
    bool last = cut == m->picture.count;
    int64_t to = last ? INT64_MAX : end;
    int64_t bytes = 0;
    result = write_segment(m, segment, cut, from, to, init, initSize, data, dataSize, &bytes);
    if (result < 0) {
        m->next = -1;
        return result;
    }
    if (!m->copyAudio) {
        bytes += m->soundBytes;
        m->soundBytes = 0;
    }
    if (info) {
        info->start = (double)m->segmentStart / 1e6;
        info->duration = (double)(end - m->segmentStart) / 1e6;
        info->sourceBytes = bytes;
    }

    queue_drop(&m->picture, cut);
    int spent = 0;
    while (spent < m->sound.count && m->sound.items[spent].time < to) spent++;
    queue_drop(&m->sound, spent);
    if (last) {
        m->next = -1;
    } else {
        m->segmentStart = end;
        m->next = segment + 1;
    }
    return 0;
}

static void video_codec(const AVCodecParameters *par, char *out, int size) {
    const uint8_t *x = par->extradata;
    if (par->codec_id == AV_CODEC_ID_HEVC && x && par->extradata_size >= 13 && x[0] == 1) {
        // ISO/IEC 14496-15 annex E: profile, compatibility flags (bit-reversed), tier and level, constraints.
        static const char *spaces[] = {"", "A", "B", "C"};
        uint32_t flags = AV_RB32(x + 2), reversed = 0;
        for (int i = 0; i < 32; i++) if (flags & (1u << i)) reversed |= 1u << (31 - i);
        // Always "L", as Jellyfin writes it: Apple TV accepts that for high-tier UHD Blu-ray video, which it plays.
        int n = snprintf(out, size, "hvc1.%s%d.%X.L%d", spaces[x[1] >> 6], x[1] & 0x1f, reversed, x[12]);
        int last = 5;
        while (last >= 0 && x[6 + last] == 0) last--;
        for (int i = 0; i <= last && n > 0 && n < size; i++) n += snprintf(out + n, size - n, ".%02X", x[6 + i]);
    } else if (par->codec_id == AV_CODEC_ID_H264 && x && par->extradata_size >= 4 && x[0] == 1) {
        snprintf(out, size, "avc1.%02X%02X%02X", x[1], x[2], x[3]);
    } else {
        snprintf(out, size, par->codec_id == AV_CODEC_ID_HEVC ? "hvc1" : "avc1");
    }
}

void reel_codecs(const ReelMedia *m, char *codecs, int codecsSize, char *supplemental, int supplementalSize) {
    const AVCodecParameters *video = m->input->streams[m->video]->codecpar;
    char picture[64];
    video_codec(video, picture, sizeof picture);
    const char *sound = NULL;
    if (m->audio >= 0) {
        if (!m->copyAudio) sound = "alac";
        else switch (m->input->streams[m->audio]->codecpar->codec_id) {
            case AV_CODEC_ID_AC3: sound = "ac-3"; break;
            case AV_CODEC_ID_EAC3: sound = "ec-3"; break;
            case AV_CODEC_ID_AAC: sound = "mp4a.40.2"; break;
            case AV_CODEC_ID_ALAC: sound = "alac"; break;
            case AV_CODEC_ID_FLAC: sound = "fLaC"; break;
            case AV_CODEC_ID_MP3: sound = "mp4a.40.34"; break;
            case AV_CODEC_ID_OPUS: sound = "Opus"; break;
            default: break;
        }
    }
    snprintf(codecs, codecsSize, sound ? "%s,%s" : "%s", picture, sound);

    supplemental[0] = 0;
    const AVPacketSideData *sd = av_packet_side_data_get(video->coded_side_data, video->nb_coded_side_data,
                                                         AV_PKT_DATA_DOVI_CONF);
    if (!sd) return;
    const AVDOVIDecoderConfigurationRecord *cfg = (const AVDOVIDecoderConfigurationRecord *)sd->data;
    // Profile 7 plays as 8.1; profile 8 says what its base layer is (1 HDR10, 2 SDR, 4 HLG).
    int compatibility = m->dolbyVision7 ? 1 : cfg->dv_bl_signal_compatibility_id;
    const char *brand = compatibility == 1 ? "db1p" : compatibility == 2 ? "db2g" : compatibility == 4 ? "db4h" : NULL;
    if ((m->dolbyVision7 || cfg->dv_profile == 8) && brand)
        snprintf(supplemental, supplementalSize, "dvh1.08.%02d/%s", cfg->dv_level, brand);
}

void reel_free(void *pointer) {
    free(pointer);
}

void reel_error_text(int error, char *buffer, int size) {
    if (av_strerror(error, buffer, (size_t)size) < 0) snprintf(buffer, (size_t)size, "Error %d", error);
}
