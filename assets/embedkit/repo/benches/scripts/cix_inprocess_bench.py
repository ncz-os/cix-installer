#!/usr/bin/env python3
"""
In-process embedding bench using llama-cpp-python.
Same nomic-embed-text-v1.5.Q8_0 GGUF model as the server path.
Eliminates HTTP overhead for true CPU-vs-CPU comparison.
"""
import json, time, statistics, sys, socket, os, platform, hashlib, glob

# Paths (override via env if running on PYTHIA)
CORPUS = os.environ.get("CORPUS", "/home/magnetar/work/mnemos-corpus.json")
MODEL  = os.environ.get("MODEL",  "/home/magnetar/work/models/nomic-embed-text-v1.5.Q8_0.gguf")
RAW    = os.environ.get("RAW",    "/home/magnetar/work/results/cix-inproc-results.jsonl")
SUMMARY= os.environ.get("SUMMARY","/home/magnetar/work/results/cix-inproc-summary.json")
N_THREADS = int(os.environ.get("N_THREADS", "12"))
N_CTX     = int(os.environ.get("N_CTX", "8192"))
ENGINE_LABEL = os.environ.get("ENGINE_LABEL", "Cix Sky1 ARM64 12-core CPU via llama-cpp-python (in-process)")

def thermal_snapshot():
    t = {}
    for z in sorted(glob.glob("/sys/class/thermal/thermal_zone*/temp")):
        try:
            with open(z) as f: v = int(f.read().strip()) / 1000.0
            with open(z.replace("/temp", "/type")) as f: name = f.read().strip()
            t[name] = v
        except Exception: pass
    return t

def main():
    print(f"[bench] corpus: {CORPUS}", flush=True)
    print(f"[bench] model:  {MODEL}", flush=True)
    print(f"[bench] threads: {N_THREADS}, ctx: {N_CTX}", flush=True)

    from llama_cpp import Llama

    print("[bench] loading model in-process...", flush=True)
    t0 = time.perf_counter()
    llm = Llama(
        model_path=MODEL,
        n_ctx=N_CTX,
        n_threads=N_THREADS,
        embedding=True,
        n_gpu_layers=0,
        verbose=False,
    )
    print(f"[bench] model loaded in {time.perf_counter()-t0:.2f}s", flush=True)

    with open(CORPUS) as f: d = json.load(f)
    recs = d["records"]
    print(f"[bench] {len(recs)} records to embed", flush=True)

    # warmup
    for s in ("warmup1", "warmup2", "warmup3"):
        llm.create_embedding(s)

    thermal_before = thermal_snapshot()
    print(f"[bench] thermal pre: {thermal_before}", flush=True)

    started = time.time()
    started_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))
    wall_ms_list = []
    raw_f = open(RAW, "w")
    failed = skip_zero = 0
    embed_dim_seen = None
    last_print = time.time()

    for idx, rec in enumerate(recs):
        rid = rec["id"]
        content = rec["payload"].get("content", "")
        if not content:
            skip_zero += 1; continue
        try:
            t0 = time.perf_counter()
            r = llm.create_embedding(content)
            wall_ms = (time.perf_counter() - t0) * 1000.0
            emb = r["data"][0]["embedding"]
            if embed_dim_seen is None: embed_dim_seen = len(emb)
            wall_ms_list.append(wall_ms)
            raw_f.write(json.dumps({"id": rid, "content_chars": len(content), "wall_ms": round(wall_ms, 3)}) + "\n")
        except Exception as e:
            failed += 1
            raw_f.write(json.dumps({"id": rid, "content_chars": len(content), "error": str(e)[:200]}) + "\n")

        now = time.time()
        if now - last_print >= 5.0 or (idx + 1) % 200 == 0:
            elapsed = now - started
            rate = (idx + 1) / max(elapsed, 1e-6)
            eta = (len(recs) - idx - 1) / max(rate, 1e-6)
            print(f"[bench] {idx+1}/{len(recs)} | {rate:.2f} rec/s | wall {elapsed:.0f}s | eta {eta:.0f}s | failed {failed}", flush=True)
            last_print = now

    raw_f.close()
    finished = time.time()
    finished_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(finished))
    total_wall_s = finished - started

    if not wall_ms_list:
        print("[bench] FATAL: no successful embeds", file=sys.stderr); sys.exit(1)

    sm = sorted(wall_ms_list); n = len(sm)
    summary = {
        "host": socket.gethostname(),
        "kernel": platform.uname().release,
        "arch": platform.uname().machine,
        "engine": ENGINE_LABEL,
        "model": "nomic-embed-text-v1.5.Q8_0.gguf",
        "model_sha256": hashlib.sha256(open(MODEL,"rb").read()).hexdigest(),
        "n_threads": N_THREADS,
        "n_ctx": N_CTX,
        "embed_dim": embed_dim_seen,
        "records_total": len(recs),
        "records_embedded": n,
        "records_failed": failed,
        "records_skipped_empty": skip_zero,
        "total_wall_s": round(total_wall_s, 3),
        "rec_per_sec": round(n / total_wall_s, 3),
        "mean_ms": round(statistics.mean(wall_ms_list), 3),
        "stdev_ms": round(statistics.stdev(wall_ms_list), 3) if n > 1 else 0,
        "p50_ms": round(sm[int(n*0.50)], 3),
        "p95_ms": round(sm[int(n*0.95)], 3),
        "p99_ms": round(sm[int(n*0.99)], 3),
        "max_ms": round(max(wall_ms_list), 3),
        "min_ms": round(min(wall_ms_list), 3),
        "started_at": started_iso,
        "finished_at": finished_iso,
        "thermal_before": thermal_before,
        "thermal_after": thermal_snapshot(),
        "raw_jsonl": RAW,
    }
    os.makedirs(os.path.dirname(SUMMARY), exist_ok=True)
    with open(SUMMARY, "w") as f: json.dump(summary, f, indent=2)
    print(f"\n[bench] DONE", flush=True)
    print(json.dumps(summary, indent=2), flush=True)

if __name__ == "__main__":
    main()
