#!/usr/bin/env python3
"""A/B 对照跑测（badger-cj 2.0 阶段 7.3）。

为什么需要：单轮数字没有统计意义（本仓基准的离散度可达 ±15%~±40%），
「A 比 B 快 3%」在单轮里可能只是噪声。本脚本做**交替 A/B**（每轮交换先后顺序，
抵消顺序/热机漂移），报中位数、配对差值、Welch t 与 p 值，禁止引用单轮 best。

同时按 docs/benchmark-methodology.md 的要求，用 mount namespace 把 /tmp
重定向到真实盘目录（/tmp 是 tmpfs，会给出错误结论），并把 cjvs 的
LD_LIBRARY_PATH 从 /tmp 软链解析到 store 真实路径（否则 bind 后加载不到运行时）。

用法：
  python3 scripts/bench/ab-compare.py \
    --bin-a <二进制A> --bin-b <二进制B> \
    --args-a "8 5000 1 on" --args-b "8 5000 1 off" \
    --label-a "mmap:on" --label-b "mmap:off" \
    --metric ns_per_txn --rounds 9 --data-dir <真实盘目录>
"""
from __future__ import annotations

import argparse
import math
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

RESULT_RE = re.compile(r"RESULT (.*)")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
WRITE_RE = re.compile(r"WRITE: .*?([0-9.]+) keys/s")


def parse_metrics(line: str) -> dict[str, float]:
    line = ANSI_RE.sub("", line)
    m = RESULT_RE.search(line)
    if m:
        out: dict[str, float] = {}
        for part in m.group(1).split():
            if "=" in part:
                k, v = part.split("=", 1)
                try:
                    out[k] = float(v)
                except ValueError:
                    pass
        return out
    m = WRITE_RE.search(line)
    if m:
        return {"keys_per_sec": float(m.group(1))}
    return {}


def resolve_library_path() -> str:
    raw = os.environ.get("LD_LIBRARY_PATH", "")
    resolved = []
    for entry in [p for p in raw.split(":") if p]:
        try:
            resolved.append(str(Path(entry).resolve()))
        except OSError:
            resolved.append(entry)
    return ":".join(resolved)


def run_once(binary: str, args: str, workdir: str, data_dir: str, heap: str) -> dict[str, float]:
    lib_path = resolve_library_path()
    cmd = (
        f"mount --bind '{data_dir}' /tmp && "
        f"cd '{workdir}' && cjHeapSize='{heap}' LD_LIBRARY_PATH='{lib_path}' '{binary}' {args}"
    )
    proc = subprocess.run(["unshare", "-rm", "bash", "-c", cmd],
                          capture_output=True, text=True, timeout=1800)
    output = proc.stdout + proc.stderr
    # 合并进程内**全部** RESULT 行（同名键取最后一次）：探针可能分阶段输出
    # （phase=start / phase=write / phase=compact …），只看第一行会漏掉真正要比的指标。
    merged: dict[str, float] = {}
    for line in output.splitlines():
        metrics = parse_metrics(line)
        if metrics:
            merged.update(metrics)
    if merged:
        return merged
    raise RuntimeError(f"no RESULT line from {binary} {args}:\n{output[-2000:]}")


def welch_p(a: list[float], b: list[float]) -> float:
    if len(a) < 2 or len(b) < 2:
        return float("nan")
    va = statistics.variance(a)
    vb = statistics.variance(b)
    se = math.sqrt(va / len(a) + vb / len(b))
    if se == 0:
        return 0.0
    t = (statistics.mean(a) - statistics.mean(b)) / se
    return 2.0 * (1.0 - 0.5 * math.erfc(-abs(t) / math.sqrt(2.0)))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin-a", required=True)
    ap.add_argument("--bin-b", required=True)
    ap.add_argument("--args-a", default="")
    ap.add_argument("--args-b", default="")
    ap.add_argument("--label-a", default="A")
    ap.add_argument("--label-b", default="B")
    ap.add_argument("--metric", default="ns_per_txn")
    ap.add_argument("--rounds", type=int, default=9)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--workdir", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--heap", default="12gb", help="仓颉 GC 堆上限（与 run-bench.py 的 HEAP 口径一致）")
    args = ap.parse_args()

    data_dir = str(Path(args.data_dir).resolve())
    Path(data_dir).mkdir(parents=True, exist_ok=True)
    workdir = args.workdir or os.getcwd()

    values_a: list[float] = []
    values_b: list[float] = []
    lines: list[str] = []
    for r in range(args.rounds):
        # 交替顺序：偶数轮 A→B，奇数轮 B→A（抵消热机/顺序漂移）
        if r % 2 == 0:
            order = [("a", args.bin_a, args.args_a), ("b", args.bin_b, args.args_b)]
        else:
            order = [("b", args.bin_b, args.args_b), ("a", args.bin_a, args.args_a)]
        for tag, binary, bin_args in order:
            metrics = run_once(os.path.abspath(binary), bin_args, workdir, data_dir, args.heap)
            if args.metric not in metrics:
                raise RuntimeError(f"metric {args.metric} missing: {metrics}")
            value = metrics[args.metric]
            if tag == "a":
                values_a.append(value)
            else:
                values_b.append(value)
            labels = {
                "a": args.label_a, "b": args.label_b,
            }
            lines.append(f"round={r} side={labels[tag]} {args.metric}={value:.3f}")
            print(lines[-1], flush=True)

    med_a = statistics.median(values_a)
    med_b = statistics.median(values_b)
    spread_a = (max(values_a) - min(values_a)) / med_a * 100 if len(values_a) > 1 else float("nan")
    spread_b = (max(values_b) - min(values_b)) / med_b * 100 if len(values_b) > 1 else float("nan")
    diffs = [a - b for a, b in zip(values_a, values_b)]
    mean_diff = statistics.mean(diffs)
    sd_diff = statistics.stdev(diffs) if len(diffs) > 1 else 0.0
    p = welch_p(values_a, values_b)

    summary = [
        f"# A/B 对照：{args.label_a} vs {args.label_b}（metric={args.metric}, rounds={args.rounds}）",
        f"# 数据目录：{data_dir}（真实盘，mount namespace 重定向 /tmp）",
        "",
    ] + lines + [
        "",
        f"summary {args.label_a}: median={med_a:.3f} spread={spread_a:.1f}%",
        f"summary {args.label_b}: median={med_b:.3f} spread={spread_b:.1f}%",
        f"summary delta_vs_b = {(med_a - med_b) / med_b * 100:.2f}% (负 = A 更快)",
        f"summary paired_mean_diff={mean_diff:.3f} sd_diff={sd_diff:.3f} welch_p={p:.4g}",
    ]
    text = "\n".join(summary)
    print("\n" + text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
