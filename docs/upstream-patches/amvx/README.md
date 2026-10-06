# amvx (cix-vpu-driver-dkms) candidate patches -- NOT shipped

Written 2026-10-06 against `assets/kernel/vpu/src` (cix-vpu-driver 1.0.2-ncz1) from the
Sky1 media investigation (`docs/SKY1-MEDIA-STATUS.md`). They are deliberately **not** in
`assets/kernel/vpu/src/patches/series`: both are compile-checked with the r285
7.3.0-rc6-sky1-ncz headers and kernel CFLAGS (no warnings) but neither has been loaded on
hardware (the test boards were read-only for module loads). Hand-off for the orchestrator /
DKMS owner to runtime-test and then add to `series`.

| patch | what | runtime evidence it addresses |
|---|---|---|
| 0001-amvx-default-decoder-capture-to-nv12.patch | decoder capture queue defaults to NV12 instead of AFBC | GStreamer `v4l2h264dec`: `V4L2 format Y0A8 not supported`, H.264/HEVC playbin3 fails on O6N and MS-R1 |
| 0002-amvx-dma-page-iterator-for-imported-dmabuf.patch | imported dma-buf walk uses `for_each_sgtable_dma_page` | latent: wrong page count/addresses behind an IOMMU or with CONFIG_DMABUF_DEBUG; no change on today's IOMMU-less Sky1 VPU |

Runtime test for 0001: `gst-launch-1.0 filesrc location=h264.mp4 ! qtdemux ! h264parse !
v4l2h264dec ! fakesink` must preroll; ffmpeg `h264_v4l2m2m` and Chromium (both S_FMT NV12
themselves) must stay bit-exact / real-time.
