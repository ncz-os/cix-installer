# MNEMOS PDF Ingest Pipeline

## Overview
Enables persistent storage and OCR processing of PDFs dropped into the session. Closes gap where PDFs were read inline but not retained as memories.

## Blob Storage Layer
- Schema: `ALTER TABLE memories ADD attachments JSONB`
- Attachment structure: `{id, mime, size, sha256, path}`
- Storage backend: Filesystem at `/data/mnemos/blobs/{sha256[:2]}/{sha256}.{ext}` on PYTHIA (NFS-backed to ARGONAS)
- Future: S3-compatible object store
- Rationale: Avoid Oracle CLOB size limits (≥4MB); use BFILE or external store

## Migration
- Script: `db/migrations_v6_2_attachments.sql`
- Target databases: Oracle, Db2, SQLite
- CI gate: migration-parity-gate

## Ingest Pipeline
1. `POST /v1/memories` with multipart: text + attachments[file=PDF]
2. Server stores raw PDF at `/data/mnemos/blobs/{sha256}.pdf`
3. Background worker extracts page images (300 DPI) using `pdfplumber` (MIT license preferred over PyMuPDF AGPL)
4. Per page:
   - PP-OCRv4 detection (text regions)
   - crnn recognition (text per region) via ZhouyiExecutionProvider on CIX NPU
5. Concatenate per-page OCR text into `memory.content`
6. Tag with `page_count` and `ocr_confidence` in metadata
7. Generate embedding using Bge-small → `memory.embedding`
8. Record original PDF in `attachments[]`

## Models (from CIX Hub)
- `latest/models/ComputeVision/OCR/onnx_PP_OCRv4` (Apache-2.0) - detection, recognition, classification
- `latest/models/ComputeVision/OCR/onnx_crnn` - text recognition fallback

## Pre-OCR Enhancers (NPU-able, conditional)
- Trigger: First-pass OCR confidence < 0.7
- `latest/models/ComputeVision/Image_Enhancement/onnx_pairlie` - low-light enhancement
- `latest/models/ComputeVision/Image_Enhancement/onnx_nighttime_dehaze` - scan dehazing

## Use Cases
- Operator drops PDF receipt/invoice/contract → auto-OCR + searchable index
- riskyEats inspection reports → OCR ingest → cross-restaurant pattern queries
- investorClaw broker statements → OCR → holdings extraction (complements v4.x portfolio upload)
- mnemos-desktop drag-drop: PDF, screenshot, image, audio (Whisper) → memories

## Acceptance Criteria
- 10-page PDF ingested in <30s on cixmini NPU (OCR + embed + persist)
- OCR text searchable via `/v1/memories/search` (text and image-query via CLIP)
- Original PDF retrievable via `GET /v1/memories/{id}/attachments/{att_id}`
- 95%+ accuracy on typeset English+Chinese mixed text (PP-OCRv4 baseline)
- Pre-OCR enhancers triggered when first-pass OCR confidence < 0.7

## Dependencies
- 019e5815-8a07 (npu-cross-encoder-rerank)
- 019e5808-1deb (hub mirror)
- 019e580c-9519 (codex audit confirmed PP-OCRv4 Apache-2.0)

## Sister Initiatives
- Derivative-work top-1: PP-OCRv4 for menu/cert/form OCR in riskyEats (same model, different ingest path)