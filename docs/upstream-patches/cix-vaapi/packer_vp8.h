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

#ifndef PACKER_VP8_H_
#define PACKER_VP8_H_

#include <vector>
#include <va/va.h>
#include <va/va_dec_vp8.h>
#include "packer.h"

/**
 * Builds the VP8 bitstream for one V4L2 OUTPUT buffer from VA slice data.
 *
 * VP8 needs no assembly: every coded frame is self-contained and the stateful
 * VPU parses it directly, so this copies one elementary frame per VA slice.
 * There is no VP8 equivalent of VP9's show_existing_frame/superframe handling -
 * VP8 has no hidden frames - so CopySlice stays a straight copy.
 *
 * VASliceParameterBufferVP8 carries slice_data_offset, which the VP9 path does
 * not use; honour it rather than assuming the frame starts at byte 0.
 */
class PackerVP8 : public Packer {
public:
    PackerVP8();
    ~PackerVP8() {}

    virtual void SetPictureParameter(void *data, uint32_t size);
    virtual void *GetPictureParameter() { return &pic_param; }
    virtual int32_t SetIQMatrix(void *data, uint32_t size);
    virtual void SetSliceParameter(void *data, uint32_t size);
    virtual void PackSpsNalu(void *out, uint32_t out_size, uint32_t &offset);
    virtual void PackPpsNalu(void *out, uint32_t out_size, uint32_t &offset, int32_t sps_id, int32_t pps_id);
    virtual void PackSliceNalu(void *out, uint32_t out_size, uint32_t &offset, void *in, uint32_t in_size, void *slice_param);
    virtual void PackFrame(void *in, uint32_t in_size, void *out, uint32_t out_size);
    virtual uint32_t CopySlice(void *out, uint32_t out_size, void *in, uint32_t in_size, bool first_slice);
    virtual int32_t CheckIntegrity();

private:
    VAPictureParameterBufferVP8 pic_param;
    std::vector<VASliceParameterBufferVP8> slice_params;
    bool pic_valid;
};

#endif  // PACKER_VP8_H_
