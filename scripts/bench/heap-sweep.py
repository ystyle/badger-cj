#!/usr/bin/env python3
"""cjHeapSize 扫描：找出「某个负载在多少堆上限下能完成」，以及峰值 RSS。

为什么需要它（P1-2 / P1-4 的判据）：

- 「流式落盘省内存」不能只引用一次成功/失败：要给出**最小可用堆**（全扫），否则读者
  无法判断省了多少、值不值得打开。
- 「arena 占用」是原生内存、不进 GC 堆，但对低堆部署同样致命，所以统一用**峰值 RSS**
  （/proc/self/status VmHWM）作为口径，比只看 GC 堆更贴近真实。

方法学与 run-bench.py / ab-compare.py 一致：unshare -rm 里把 /tmp bind 到真实盘目录，
避免 tmpfs 让 I/O 成绩虚高；同时把 cjvs 的 LD_LIBRARY_PATH 解析成真实路径。

用法：
  python3 scripts/bench/heap-sweep.py \
    --bin target/release/bin/badgercj.examples.mem_profile \
    --data-dir <真实盘目录> \
    --heaps 48,64,96,128,192,256,512 \
    --cases "flush-plain:flush 0 16 2 32 1024 1;flush-stream:flush 1 16 2 32 1024 1" \
    --out <输出 md>
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
RESULT_RE = re.compile(r"RESULT (.*)")
OOM_HINTS = ("OutOfMemory", "out of memory", "flush system error",
             "Failed to allocate", "memory exhausted")


def resolve_library_path() -> str:
    raw = os.environ.get("LD_LIBRARY_PATH", "")
    out = []
    for entry in [p for p in raw.split(":") if p]:
        try:
            out.append(str(Path(entry).resolve()))
        except OSError:
            out.append(entry)
    return ":".join(out)


def parse_results(output: str) -> list:
    rows = []
    for line in output.splitlines():
        line = ANSI_RE.sub("", line)
        m = RESULT_RE.search(line)
        if not m:
            continue
        row = {}
        for part in m.group(1).split():
            if "=" not in part:
                continue
            k, v = part.split("=", 1)
            try:
                row[k] = float(v)
            except ValueError:
                row[k] = v
        rows.append(row)
    return rows


def run_case(binary, args, workdir, data_dir, heap_mb, timeout):
    lib_path = resolve_library_path()
    heap = "12gb" if heap_mb <= 0 else "%dMB" % heap_mb
    cmd = ("mount --bind '%s' /tmp && cd '%s' && cjHeapSize='%s' LD_LIBRARY_PATH='%s' '%s' %s"
           % (data_dir, workdir, heap, lib_path, binary, args))
    try:
        proc = subprocess.run(["unshare", "-rm", "bash", "-c", cmd],
                              capture_output=True, text=True, timeout=timeout)
        output, code = proc.stdout + proc.stderr, proc.returncode
    except subprocess.TimeoutExpired:
        return {"ok": False, "reason": "timeout", "rows": [], "log": ""}
    oom = any(h in output for h in OOM_HINTS)
    rows = parse_results(output)
    ok = code == 0 and not oom and bool(rows)
    reason = "ok" if ok else ("oom" if oom else "exit=%d" % code)
    return {"ok": ok, "reason": reason, "rows": rows, "log": output[-2000:]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--workdir", default="")
    ap.add_argument("--heaps", default="48,64,96,128,192,256,512")
    ap.add_argument("--cases", required=True, help="标签:参数；多组用 ; 分隔")
    ap.add_argument("--out", default="")
    ap.add_argument("--json", default="")
    # 默认 120s：低堆下写路径可能长时间重试（flush 失败 → 等腾位），不能被当成"能跑"
    # 无限等；超时即判失败（并记录 timeout，便于区分"挂住"与"明确 OOM"）。
    ap.add_argument("--timeout", type=int, default=120)
    # --bisect：在 --heaps 给的候选里二分找「最小可用堆」，比全量扫描省一半以上的跑次
    ap.add_argument("--bisect", action="store_true")
    args = ap.parse_args()

    data_dir = str(Path(args.data_dir).resolve())
    binary = str(Path(args.bin).resolve())
    workdir = args.workdir or str(Path(args.bin).resolve().parents[2])

    cases = []
    for spec in args.cases.split(";"):
        spec = spec.strip()
        if not spec:
            continue
        label, _, rest = spec.partition(":")
        cases.append((label.strip(), rest.strip()))
    heaps = [int(h) for h in args.heaps.split(",") if h.strip()]

    results = []
    print("[sweep] data_dir=%s cases=%d heaps=%s bisect=%s"
          % (data_dir, len(cases), heaps, args.bisect), file=sys.stderr)

    def run_one(label, cargs, heap):
        r = run_case(binary, cargs, workdir, data_dir, heap, args.timeout)
        peak = 0.0
        for row in r["rows"]:
            if "peakRssKB" in row:
                peak = max(peak, float(row["peakRssKB"]))
        results.append({"case": label, "heapMB": heap, "ok": r["ok"],
                        "reason": r["reason"], "peakRssKB": peak, "rows": r["rows"]})
        status = "OK  " if r["ok"] else "FAIL"
        print("[sweep] %-24s heap=%5dMB %s %-10s peakRss=%8.1fMB"
              % (label, heap, status, r["reason"], peak / 1024.0), file=sys.stderr)
        return r["ok"]

    for label, cargs in cases:
        min_ok = None
        if args.bisect:
            lo, hi = 0, len(heaps) - 1
            # 先确认上界能过、下界过不去，再二分
            if not run_one(label, cargs, heaps[hi]):
                print("[sweep] %s: 上界 %dMB 仍失败（+%s），请抬高 --heaps"
                      % (label, heaps[hi], ""), file=sys.stderr)
                continue
            if run_one(label, cargs, heaps[lo]):
                print("[sweep] %s: 下界 %dMB 即通过，可再降" % (label, heaps[lo]), file=sys.stderr)
                min_ok = heaps[lo]
            else:
                while hi - lo > 1:
                    mid = (lo + hi) // 2
                    if run_one(label, cargs, heaps[mid]):
                        hi = mid
                    else:
                        lo = mid
                min_ok = heaps[hi]
        else:
            for heap in heaps:
                if run_one(label, cargs, heap) and min_ok is None:
                    min_ok = heap
        print("[sweep] %s: 最小可用堆 = %s MB" % (label, min_ok), file=sys.stderr)

    lines = ["| 用例 | cjHeapSize | 结果 | 峰值 RSS (MB) |", "|---|---|---|---|"]
    for e in results:
        res = "通过" if e["ok"] else "失败（%s）" % e["reason"]
        lines.append("| %s | %d MB | %s | %.1f |"
                     % (e["case"], e["heapMB"], res, e["peakRssKB"] / 1024.0))
    table = "\n".join(lines)
    print(table)
    if args.out:
        Path(args.out).write_text(table + "\n", encoding="utf-8")
    if args.json:
        Path(args.json).write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())