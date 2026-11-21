#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#include <stdlib.h>
#include <string.h>
#include "minimp3_ex.h"
#include "include/cminimp3.h"

static size_t id3v2_size(const uint8_t *buf, size_t len)
{
    if (len >= 10 && !memcmp(buf, "ID3", 3) && !((buf[5] & 15) || (buf[6] & 0x80) ||
        (buf[7] & 0x80) || (buf[8] & 0x80) || (buf[9] & 0x80))) {
        size_t size = (((buf[6] & 0x7f) << 21) | ((buf[7] & 0x7f) << 14) |
                       ((buf[8] & 0x7f) << 7) | (buf[9] & 0x7f)) + 10;
        if ((buf[5] & 16)) size += 10; /* footer */
        return size;
    }
    return 0;
}

int cmp3_find_tag_frame(const uint8_t *buf, size_t len, size_t *frame_offset,
                        size_t *frame_size, int *is_tag_frame)
{
    size_t skip = id3v2_size(buf, len);
    if (skip >= len) return -1;
    const uint8_t *p = buf + skip;
    size_t remain = len - skip;
    int free_format_bytes = 0, ptr_frame_bytes = 0;
    int i = mp3d_find_frame(p, (int)(remain > 0x7fffffff ? 0x7fffffff : remain),
                            &free_format_bytes, &ptr_frame_bytes);
    if (ptr_frame_bytes <= 0) return -2;
    const uint8_t *hdr = p + i;
    uint32_t frames = 0;
    int delay = 0, padding = 0;
    int ret = mp3dec_check_vbrtag(hdr, ptr_frame_bytes, &frames, &delay, &padding);
    *frame_offset = skip + (size_t)i;
    *frame_size = (size_t)ptr_frame_bytes;
    *is_tag_frame = (ret > 0) ? 1 : 0;
    return 0;
}

int cmp3_decode(const uint8_t *buf, size_t len, int honor_gapless, cmp3_result *out)
{
    memset(out, 0, sizeof(*out));
    size_t tag_off = 0, tag_size = 0; int is_tag = 0;
    if (cmp3_find_tag_frame(buf, len, &tag_off, &tag_size, &is_tag) == 0 && is_tag) {
        uint32_t frames = 0; int delay = 0, padding = 0;
        mp3dec_check_vbrtag(buf + tag_off, (int)tag_size, &frames, &delay, &padding);
        out->has_vbr_tag = 1;
        out->tag_delay = delay;
        out->tag_padding = padding;
        out->tag_frame_offset = tag_off;
        out->tag_frame_size = tag_size;
    }

    mp3dec_t dec;
    mp3dec_file_info_t info;
    memset(&info, 0, sizeof(info));
    int ret;
    if (honor_gapless || !out->has_vbr_tag) {
        ret = mp3dec_load_buf(&dec, buf, len, &info, NULL, NULL);
    } else {
        /* Naive decode: remove the tag frame so no delay/padding gets applied. */
        uint8_t *copy = (uint8_t *)malloc(len - tag_size);
        if (!copy) return -2;
        memcpy(copy, buf, tag_off);
        memcpy(copy + tag_off, buf + tag_off + tag_size, len - tag_off - tag_size);
        ret = mp3dec_load_buf(&dec, copy, len - tag_size, &info, NULL, NULL);
        free(copy);
    }
    if (ret != 0) { if (info.buffer) free(info.buffer); return ret < 0 ? ret : -5; }
    if (!info.buffer || info.channels <= 0) { if (info.buffer) free(info.buffer); return -5; }
    out->pcm = info.buffer;
    out->channels = info.channels;
    out->sample_rate = info.hz;
    out->frames = info.samples / (size_t)info.channels;
    return 0;
}

void cmp3_free(cmp3_result *r)
{
    if (r && r->pcm) { free(r->pcm); r->pcm = NULL; }
}
