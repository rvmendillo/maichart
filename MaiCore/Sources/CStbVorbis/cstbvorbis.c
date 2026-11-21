// Thin float-output wrapper around stb_vorbis (public domain / MIT, Sean Barrett).
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#include "include/cstbvorbis.h"
#include <stdlib.h>

int csv_decode(const unsigned char *data, int length, float **out, int *channels, int *sampleRate, long *frames) {
    int err = 0;
    *out = NULL; *channels = 0; *sampleRate = 0; *frames = 0;
    stb_vorbis *v = stb_vorbis_open_memory(data, length, &err, NULL);
    if (!v) return err != 0 ? err : -1;
    stb_vorbis_info info = stb_vorbis_get_info(v);
    int ch = info.channels;
    if (ch <= 0) { stb_vorbis_close(v); return -1; }
    unsigned int known = stb_vorbis_stream_length_in_samples(v);
    long cap = known > 0 ? (long)known + 4096 : (long)info.sample_rate * 60;
    if (cap < 4096) cap = 4096;
    float *buf = (float *)malloc(sizeof(float) * (size_t)cap * (size_t)ch);
    if (!buf) { stb_vorbis_close(v); return -1; }
    long n = 0;
    for (;;) {
        if (cap - n < 4096) {
            long ncap = cap * 2;
            float *nb = (float *)realloc(buf, sizeof(float) * (size_t)ncap * (size_t)ch);
            if (!nb) { free(buf); stb_vorbis_close(v); return -1; }
            buf = nb; cap = ncap;
        }
        int got = stb_vorbis_get_samples_float_interleaved(v, ch, buf + n * ch, (int)((cap - n) * ch));
        if (got <= 0) break;
        n += got;
    }
    stb_vorbis_close(v);
    *out = buf; *channels = ch; *sampleRate = (int)info.sample_rate; *frames = n;
    return 0;
}

void csv_free(float *buffer) { free(buffer); }
