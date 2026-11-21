#ifndef CMINIMP3_H
#define CMINIMP3_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result of decoding a whole MP3 buffer to interleaved float PCM. */
typedef struct {
    float   *pcm;          /* interleaved samples, malloc'ed, free with cmp3_free */
    size_t   frames;       /* sample frames (per channel) */
    int      channels;
    int      sample_rate;
    int      has_vbr_tag;  /* 1 when a Xing/Info/VBRI header frame was found */
    int      tag_delay;    /* encoder delay + 529 decoder delay from LAME tag (frames) */
    int      tag_padding;  /* end padding from LAME tag (frames) */
    size_t   tag_frame_offset; /* byte offset of the tag frame (when has_vbr_tag) */
    size_t   tag_frame_size;   /* byte length of the tag frame (when has_vbr_tag) */
} cmp3_result;

/* honor_gapless = 1: skip encoder/decoder delay and padding described by a LAME tag
   (what a gapless-aware player outputs).
   honor_gapless = 0: output every decoded sample (what a naive player outputs),
   only the tag frame itself is skipped.
   Returns 0 on success, negative on failure. */
int  cmp3_decode(const uint8_t *buf, size_t len, int honor_gapless, cmp3_result *out);
void cmp3_free(cmp3_result *r);

/* Locate the first MPEG audio frame (after any ID3v2 tag) and report whether it
   is a Xing/Info/VBRI header frame. Returns 0 on success. */
int  cmp3_find_tag_frame(const uint8_t *buf, size_t len, size_t *frame_offset,
                         size_t *frame_size, int *is_tag_frame);

#ifdef __cplusplus
}
#endif
#endif
