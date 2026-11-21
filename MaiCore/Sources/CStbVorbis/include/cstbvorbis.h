#ifndef CSTBVORBIS_H
#define CSTBVORBIS_H

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes a complete Ogg Vorbis file held in memory to interleaved 32-bit float PCM.
/// Returns 0 on success (caller frees *out with csv_free), otherwise a stb_vorbis error code (or -1).
int csv_decode(const unsigned char *data, int length, float **out, int *channels, int *sampleRate, long *frames);
void csv_free(float *buffer);

#ifdef __cplusplus
}
#endif

#endif
