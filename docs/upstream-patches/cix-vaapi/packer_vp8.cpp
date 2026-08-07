/*
 * Copyright 2026 NCZ
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 */

#include <cstring>
#include "packer_vp8.h"
#include "log.h"

PackerVP8::PackerVP8() :
    pic_valid(false)
{
    memset(&pic_param, 0, sizeof(pic_param));
}

void PackerVP8::SetPictureParameter(void *data, uint32_t size)
{
    if (!data || size < sizeof(VAPictureParameterBufferVP8)) {
        CIX_VAAPI_WARNING("VP8: picture parameter buffer is %u B, expected %zu\n",
            size, sizeof(VAPictureParameterBufferVP8));
        return;
    }

    memcpy(&pic_param, data, sizeof(pic_param));
    pic_valid = true;
    slice_params.clear();
}

int32_t PackerVP8::SetIQMatrix(void *data, uint32_t size)
{
    /* VP8 quantisation lives in the frame header; nothing to merge here. */
    (void)data;
    (void)size;
    return 0;
}

void PackerVP8::SetSliceParameter(void *data, uint32_t size)
{
    uint32_t n = size / sizeof(VASliceParameterBufferVP8);
    if (!data || n == 0 || size % sizeof(VASliceParameterBufferVP8) != 0) {
        CIX_VAAPI_WARNING("VP8: slice parameter buffer is %u B, not a multiple of %zu\n",
            size, sizeof(VASliceParameterBufferVP8));
        return;
    }

    VASliceParameterBufferVP8 *sp = (VASliceParameterBufferVP8 *)data;
    for (uint32_t i = 0; i < n; i++)
        slice_params.push_back(sp[i]);
}

void PackerVP8::PackSpsNalu(void *out, uint32_t out_size, uint32_t &offset)
{
    /* VP8 has no out-of-band sequence header. */
    (void)out;
    (void)out_size;
    (void)offset;
}

void PackerVP8::PackPpsNalu(void *out, uint32_t out_size, uint32_t &offset, int32_t sps_id, int32_t pps_id)
{
    (void)out;
    (void)out_size;
    (void)offset;
    (void)sps_id;
    (void)pps_id;
}

void PackerVP8::PackSliceNalu(void *out, uint32_t out_size, uint32_t &offset, void *in, uint32_t in_size, void *slice_param)
{
    (void)out;
    (void)out_size;
    (void)offset;
    (void)in;
    (void)in_size;
    (void)slice_param;
}

void PackerVP8::PackFrame(void *in, uint32_t in_size, void *out, uint32_t out_size)
{
    if (!in || !out || in_size > out_size)
        return;

    memcpy(out, in, in_size);
}

uint32_t PackerVP8::CopySlice(void *out, uint32_t out_size, void *in, uint32_t in_size, bool first_slice)
{
    (void)first_slice;

    if (!out || !in) {
        CIX_VAAPI_ERROR("VP8: CopySlice called with out=%p in=%p\n", out, in);
        return 0;
    }
    if (slice_params.empty()) {
        CIX_VAAPI_ERROR("VP8: no slice parameters; cannot locate the frame payload\n");
        return 0;
    }

    /* One coded frame per VA slice. Unlike VP9, VP8 slice parameters carry a
     * data offset, so do not assume the frame starts at the buffer origin. */
    const VASliceParameterBufferVP8 &sp = slice_params[0];
    const uint32_t nbytes = sp.slice_data_size;
    const uint32_t start = sp.slice_data_offset;

    if (nbytes == 0) {
        CIX_VAAPI_ERROR("VP8: slice_data_size is 0\n");
        return 0;
    }
    if (start > in_size || nbytes > in_size - start) {
        CIX_VAAPI_ERROR("VP8: slice at offset %u size %u exceeds slice buffer %u\n",
            start, nbytes, in_size);
        return 0;
    }
    if (nbytes > out_size) {
        CIX_VAAPI_ERROR("VP8: frame size %u exceeds output plane %u\n", nbytes, out_size);
        return 0;
    }

    memcpy(out, (const uint8_t *)in + start, nbytes);
    return nbytes;
}

int32_t PackerVP8::CheckIntegrity()
{
    if (!pic_valid) {
        CIX_VAAPI_ERROR("VP8: no picture parameters were supplied for this frame\n");
        return -1;
    }
    if (slice_params.empty()) {
        CIX_VAAPI_ERROR("VP8: no slice parameters were supplied for this frame\n");
        return -1;
    }

    return 0;
}
