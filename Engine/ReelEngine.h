#ifndef REEL_ENGINE_H
#define REEL_ENGINE_H

// Turns a film (MKV, M2TS, MP4…) into fragmented-MP4 segments AVPlayer can play, as it plays.
// The picture is never re-encoded. Sound iOS can't decode (DTS, DTS-HD MA, TrueHD…) becomes Apple Lossless.
// A ReelMedia is used from one thread at a time; only reel_cancel may be called from another.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ReelMedia ReelMedia;

/// Reads up to `length` bytes at `offset`. Returns the count read, or a negative number on failure.
typedef int (*ReelRead)(void *context, int64_t offset, uint8_t *buffer, int length);

typedef enum { ReelKindVideo = 1, ReelKindAudio = 2, ReelKindSubtitle = 3 } ReelKind;
typedef enum { ReelRangeSDR = 0, ReelRangePQ = 1, ReelRangeHLG = 2 } ReelRange;

typedef struct {
    int index;
    ReelKind kind;
    char codec[32];
    char profile[40];
    char language[8];
    char title[96];
    int pid;              // MPEG-TS only
    int width, height;
    int channels;
    bool isDefault, isForced, isCommentary;
    bool playable;
    bool untouched;       // false when sound is converted
    bool lossless;
    ReelRange range;
    int dolbyVision;      // Dolby Vision profile as it plays (5 or 8), 0 for none
    double frameRate;
} ReelStream;

/// A change in what the subtitles show. No text and no bitmap means clear the screen.
/// Pointers are valid only during the callback.
typedef struct {
    double start;
    double end;           // negative: until the next cue
    int canvasWidth, canvasHeight;
    int x, y, width, height;
    const uint8_t *rgba;  // width * height * 4, straight alpha
    const char *text;
    bool continues;       // another rectangle of the cue before it
} ReelCue;

typedef void (*ReelCueHandler)(void *context, const ReelCue *cue);

typedef struct {
    double start, duration;
    int64_t sourceBytes;  // picture plus the chosen sound, as stored in the film
} ReelSegmentInfo;

ReelMedia *reel_open(ReelRead read, void *context, int64_t size, int *error);
void reel_cancel(ReelMedia *media);
void reel_close(ReelMedia *media);

double reel_duration(const ReelMedia *media);
int reel_stream_count(const ReelMedia *media);
bool reel_stream(const ReelMedia *media, int position, ReelStream *out);

/// Pass -1 for no sound or no subtitles. Call before asking for segments.
int reel_select(ReelMedia *media, int audio, int subtitle, ReelCueHandler handler, void *context);
int reel_segment_count(const ReelMedia *media);
double reel_segment_duration(const ReelMedia *media, int segment);

/// On success `init` (optional) and `data` are the caller's, to free with reel_free.
int reel_segment(ReelMedia *media, int segment, uint8_t **init, int *initSize,
                 uint8_t **data, int *dataSize, ReelSegmentInfo *info);
void reel_free(void *pointer);

/// How HLS names what plays, after reel_select: `codecs` like "hvc1.2.4.L153.B0,alac", and for Dolby Vision
/// `supplemental` like "dvh1.08.06/db1p" (empty otherwise). Lets Apple TV switch the TV to the right mode first.
void reel_codecs(const ReelMedia *media, char *codecs, int codecsSize, char *supplemental, int supplementalSize);
void reel_error_text(int error, char *buffer, int size);

#ifdef __cplusplus
}
#endif

#endif
