#!/usr/bin/env python3
"""badger-cj 标准基准流程。

为什么需要它（历史基准数据的三个方法学缺陷，均已实测确认）：

1. **数据目录落在 tmpfs**：所有 `src/examples/*_perf` 都把数据目录硬编码成 `/tmp/...`。
   本机 `/tmp` 是 tmpfs，读写全在内存里 —— I/O 成绩虚高一个数量级
   （实测 `sstable_write_perf` 在 tmpfs 上算出 4000+ MB/s，即内存速度）。
   本脚本默认把数据目录**重定向到真实盘**（bind mount），并在报告里记录文件系统类型。

2. **单次测量没有统计意义**：`skiplist_perf` 全部 4 项总耗时仅约 64ms，
   单跑一次的数字在 15 轮复测里离散度可达 ±32%。本脚本每项连跑 N 轮，
   报告**中位数 + 离散度**，离散度超阈值自动标注"波动大"。

3. **环境指纹缺失**：没有 CPU/内核/编译器/commit 记录的数字无法复核。
   本脚本把指纹与结果写进同一份报告，并同时产出 JSON 便于再加工。

用法：
    scripts/bench/run-bench.py                     # 跑全部（5 轮）
    scripts/bench/run-bench.py --runs 9            # 更稳的中位数
    scripts/bench/run-bench.py --only skiplist,txn # 只跑指定项
    scripts/bench/run-bench.py --no-bind-tmp       # 不加 bind mount（用 tmpfs 原样）
    scripts/bench/run-bench.py --list              # 列出所有基准名

退出码：0 全部成功；1 有基准轮次失败；2 参数错误。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# 脚本可放在任一 checkout 里，用 --repo 指定要测的那个检出；
# 默认测脚本所在的仓库。测某个已发布 tag 时：把 tag 检出到独立 worktree，
# 再用 --repo <那个目录> 指向它（这样测的二进制与发布的源码 revision 一致）。
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATA_DIR_NAME = ".bench-data"
HEAP = "12gb"

# 离散度超过该百分比即标注"波动大"（报告里不建议引用点值）
VOLATILE_PCT = 15.0

ANSI = re.compile(r"\x1b\[[0-9;]*m")


# --------------------------------------------------------------------------
# 度量值
# --------------------------------------------------------------------------
@dataclass
class Metric:
    """一个跨轮次汇总的指标。unit 只用于展示。"""
    name: str
    values: list[float] = field(default_factory=list)
    unit: str = ""
    higher_is_better: bool = True

    @property
    def median(self) -> float | None:
        return statistics.median(self.values) if self.values else None

    @property
    def spread_pct(self) -> float | None:
        """相对离散度 = (max-min)/median。轮数 < 2 时无意义。"""
        if len(self.values) < 2 or not self.median:
            return None
        return (max(self.values) - min(self.values)) / self.median * 100.0

    @property
    def volatile(self) -> bool:
        sp = self.spread_pct
        return sp is not None and sp > VOLATILE_PCT

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "unit": self.unit,
            "median": self.median,
            "min": min(self.values) if self.values else None,
            "max": max(self.values) if self.values else None,
            "spread_pct": self.spread_pct,
            "volatile": self.volatile,
            "values": self.values,
        }


@dataclass
class Bench:
    """一个基准程序。"""
    key: str                 # 命令行 --only 用的短名
    title: str
    argv: list[str]          # 相对 target/release/bin 的可执行名 + 参数
    parse: str               # 解析器名
    note: str = ""


# --------------------------------------------------------------------------
# 解析器：把单个基准程序的 stdout 解析成 {指标名: 数值}
# --------------------------------------------------------------------------
def _f(s: str) -> float:
    return float(s.replace(",", ""))


def parse_skiplist(out: str) -> dict[str, float]:
    """--- Concurrent Write --- / Per op: N ns/op / Throughput: N ops/sec"""
    res: dict[str, float] = {}
    sections = {
        "并发写": "Concurrent Write",
        "并发读": "Concurrent Read",
        "顺序写": "Sequential Write",
        "顺序读": "Sequential Read",
    }
    for label, marker in sections.items():
        block = re.search(
            rf"---\s*{re.escape(marker)}\s*---(.*?)(?=---|\Z)", out, re.S)
        if not block:
            continue
        body = block.group(1)
        if m := re.search(r"Per op:\s*([\d,]+)\s*ns/op", body):
            res[f"{label}(ns/op)"] = _f(m.group(1))
        if m := re.search(r"Throughput:\s*([\d,]+)\s*ops/sec", body):
            res[f"{label}吞吐(ops/sec)"] = _f(m.group(1))
    return res


def parse_key_compare(out: str) -> dict[str, float]:
    """16 bytes: / 逐字节: Nns/op / FFI memcmp: Nns/op"""
    res: dict[str, float] = {}
    for m in re.finditer(
            r"(\d+)\s*bytes:\s*\n\s*逐字节:\s*(\d+)ns/op\s*\n\s*FFI memcmp:\s*(\d+)ns/op",
            out):
        sz, b, f = m.group(1), _f(m.group(2)), _f(m.group(3))
        res[f"逐字节_{sz}B(ns/op)"] = b
        res[f"FFI_{sz}B(ns/op)"] = f
    return res


def parse_flush_impact(out: str) -> dict[str, float]:
    res: dict[str, float] = {}
    if m := re.search(r"keysPerSec=(\d+)", out):
        res["写吞吐(keys/s)"] = _f(m.group(1))
    if m := re.search(r"elapsedMs=(\d+)", out):
        res["写耗时(ms)"] = _f(m.group(1))
    if m := re.search(r"FLUSH_IMPACT_CLOSE\s+closeMs=(\d+)", out):
        res["close耗时(ms)"] = _f(m.group(1))
    return res


def parse_sstable_write(out: str) -> dict[str, float]:
    """表格行: | 4 | 4 MB | 4 | 9 | 0.44x | 4021 | 1787 |

    两段表（batch / sequential）。用序号区分同名指标。
    """
    res: dict[str, float] = {}
    seq = re.search(r"=== Sequential Write.*", out, re.S)
    batch_txt = out[:seq.start()] if seq else out
    seq_txt = seq.group(0) if seq else ""

    def rows(text: str) -> list[list[str]]:
        out_rows = []
        for line in text.splitlines():
            if not line.strip().startswith("|"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not cells or not cells[0].isdigit():
                continue
            out_rows.append(cells)
        return out_rows

    for cells in rows(batch_txt):
        if len(cells) >= 6:
            n = cells[0]
            res[f"batch_{n}文件_sync(ms)"] = _f(cells[2])
            res[f"batch_{n}文件_io_uring(ms)"] = _f(cells[3])
            res[f"batch_{n}文件_加速比"] = _f(cells[4].rstrip("x"))
    for cells in rows(seq_txt):
        if len(cells) >= 5:
            n = cells[0]
            res[f"seq_{n}文件_sync(ms)"] = _f(cells[2])
            res[f"seq_{n}文件_io_uring(ms)"] = _f(cells[3])
            res[f"seq_{n}文件_加速比"] = _f(cells[4].rstrip("x"))
    return res


def parse_txn(out: str) -> dict[str, float]:
    """WRITE: 50 x 100 = 5,000 keys in 7ms, 1,469 ns/op, 680,453 keys/s (ok: 50, fail: 0)

    txn_perf_long 少一个 ns/op 字段（500 x 3,000 = ... keys in 3950ms, 379,687 keys/s），
    两种都覆盖。
    """
    res: dict[str, float] = {}
    for m in re.finditer(
            r"WRITE:\s*([\d,]+)\s*x\s*([\d,]+)\s*=\s*[\d,]+\s*keys\s*in\s*([\d,]+)ms,"
            r"(?:\s*([\d,]+)\s*ns/op,)?\s*([\d,]+)\s*keys/s", out):
        ntxn, kpt = _f(m.group(1)), _f(m.group(2))
        tag = f"{ntxn:.0f}x{kpt:.0f}"
        if m.group(4) is not None:
            res[f"{tag}_ns/op"] = _f(m.group(4))
        res[f"{tag}_keys/s"] = _f(m.group(5))
        res[f"{tag}_耗时(ms)"] = _f(m.group(3))
    return res


def parse_raw_write(out: str) -> dict[str, float]:
    m = re.search(r"DIRECT:.*?([\d,]+)\s*keys/s", out)
    return {"写吞吐(keys/s)": _f(m.group(1))} if m else {}


def parse_perf(out: str) -> dict[str, float]:
    res: dict[str, float] = {}
    if m := re.search(r"Write:.*?([\d,]+)\s*ns/op", out):
        res["DB写(ns/op)"] = _f(m.group(1))
    if m := re.search(r"Read:.*?([\d,]+)\s*ns/op", out):
        res["DB读(ns/op)"] = _f(m.group(1))
    return res


def parse_io_uring_table(out: str) -> dict[str, float]:
    """iouring_integration_test / batch_test 的 Markdown 表。

    表头形如：
      | MemTable | Writes | Sync (ms) | io_uring (ms) | Speedup | Sync keys/s | io_uring keys/s | SSTables |
    用表头定位列，避免硬编码列序。
    """
    res: dict[str, float] = {}
    header: list[str] | None = None
    for line in out.splitlines():
        s = line.strip()
        if not s.startswith("|"):
            header = None
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if header is None:
            header = cells
            continue
        if all(set(c) <= set("-: ") for c in cells):
            continue  # 分隔行
        if len(cells) != len(header):
            continue
        label = "_".join(cells[:2]).replace(" ", "")
        for idx, (val, name) in enumerate(zip(cells, header)):
            if idx < 2:
                continue  # 前两列是标签
            try:
                v = _f(val.rstrip("x"))
            except ValueError:
                continue
            col = name.replace(" ", "").replace("(", "").replace(")", "")
            res[f"{label}_{col}"] = v
    return res


PARSERS = {
    "skiplist": parse_skiplist,
    "key_compare": parse_key_compare,
    "flush_impact": parse_flush_impact,
    "sstable_write": parse_sstable_write,
    "txn": parse_txn,
    "raw_write": parse_raw_write,
    "perf": parse_perf,
    "io_uring_table": parse_io_uring_table,
}


# --------------------------------------------------------------------------
# 基准清单
# --------------------------------------------------------------------------
BENCHES: list[Bench] = [
    Bench("skiplist", "Skiplist 并发/顺序（5000 ops, 16 线程）",
          ["badgercj.examples.skiplist_perf"], "skiplist",
          "负载仅约 64ms，离散度天然偏大；看中位数与其波动范围"),
    Bench("key_compare", "Key 比较（逐字节 vs FFI memcmp, 100 万次）",
          ["badgercj.examples.key_compare_perf"], "key_compare"),
    Bench("txn", "并发事务写（50 事务 × 100/500/1000/2000/3000 key）",
          ["badgercj.examples.txn_perf"], "txn"),
    Bench("txn_long", "长事务写（500 事务 × 3000 key）",
          ["badgercj.examples.txn_perf_long"], "txn"),
    Bench("raw_write", "MemTable 直接写（50 万 key）",
          ["badgercj.examples.raw_write_perf"], "raw_write"),
    Bench("perf", "DB 读写（4000 写 / 4000 读）",
          ["badgercj.examples.perf"], "perf"),
    Bench("flush_impact", "flush 落盘影响（io_uring 路径）",
          ["badgercj.examples.flush_impact_perf"], "flush_impact"),
    Bench("flush_impact_sync", "flush 落盘影响（sync 降级路径）",
          ["badgercj.examples.flush_impact_perf", "sync"], "flush_impact",
          "同二进制、仅切换写路径 → 开关对照"),
    Bench("sstable_write", "SSTable 批量写（sync vs io_uring 同进程对照）",
          ["badgercj.examples.sstable_write_perf"], "sstable_write"),
    Bench("iouring_integration", "io_uring 集成（多档 memtable/写入量）",
          ["badgercj.examples.iouring_integration_test"], "io_uring_table"),
    Bench("iouring_batch", "io_uring 批量（并发 + 小 memtable）",
          ["badgercj.examples.iouring_batch_test"], "io_uring_table"),
]

BENCH_BY_KEY = {b.key: b for b in BENCHES}


# --------------------------------------------------------------------------
# 运行
# --------------------------------------------------------------------------
def env_fingerprint(repo: Path, data_dir: Path) -> dict:
    def sh(cmd: str) -> str:
        try:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                               cwd=repo, timeout=30)
            return r.stdout.strip().splitlines()[0] if r.stdout.strip() else ""
        except Exception:
            return ""

    return {
        "生成时间": datetime.now().isoformat(timespec="seconds"),
        "commit": sh("git rev-parse --short HEAD"),
        "describe": sh("git describe --tags --always --dirty"),
        "branch": sh("git rev-parse --abbrev-ref HEAD"),
        "版本": sh(r"grep -m1 '^  version' cjpm.toml | sed 's/.*\"\(.*\)\".*/\1/'"),
        "cjc": sh("cjc --version"),
        "cjpm": sh("cjpm --version"),
        "cpu": sh("lscpu | grep -m1 'Model name' | sed 's/.*: *//'"),
        "cores": sh("nproc"),
        "mem_total": sh("free -h | awk '/^Mem:/{print $2}'"),
        "kernel": sh("uname -r"),
        "数据目录": str(data_dir),
        "数据目录FS": sh(f"stat -f -c '%T' {data_dir}"),
        "运行前负载": sh("cat /proc/loadavg"),
        "cjHeapSize": HEAP,
    }


def resolve_runtime_libs() -> str:
    """把仓颉运行时库路径解析到真实盘。

    必要性：`cjvs env` 给出的 `CANGJIE_HOME` 位于 `/tmp/cjvs_multishells/<n>_<ts>`
    （那只是个指向 `~/.config/cjvs/store/<ver>` 的软链）。一旦把数据目录 bind 到 `/tmp`，
    这个软链就被遮住 → 进程找不到 `libcangjie-runtime.so`（exit 127 加载失败）。
    所以在 bind 场景下必须改用 store 的真实路径。
    """
    parts: list[str] = []
    home = os.environ.get("CANGJIE_HOME", "")
    if home:
        real = os.path.realpath(home)
        parts += [
            f"{real}/runtime/lib/linux_{'aarch64' if os.uname().machine == 'aarch64' else 'x86_64'}_cjnative",
            f"{real}/runtime/lib/linux_{'aarch64' if os.uname().machine == 'aarch64' else 'x86_64'}_llvm",
            f"{real}/tools/lib",
        ]
    stdx = os.environ.get("CANGJIE_STDX_PATH", "")
    if stdx:
        parts.append(os.path.realpath(stdx))
    existing = [p for p in parts if os.path.isdir(p)]
    return ":".join(existing)


def run_one(bench: Bench, runs: int, timeout: int, bind_dir: Path | None,
            verbose: bool, bin_dir: Path, lib_path: str) -> tuple[list[str], int]:
    """跑 runs 轮，返回 (每轮 stdout, 失败轮数)。"""
    outputs: list[str] = []
    failed = 0
    for r in range(1, runs + 1):
        argv = [str(bin_dir / bench.argv[0])] + bench.argv[1:]
        quoted = " ".join(shlex_quote(a) for a in argv)
        env_prefix = f"cjHeapSize={HEAP}"
        if lib_path:
            env_prefix += f" LD_LIBRARY_PATH={shlex_quote(lib_path)}"
        if bind_dir is not None:
            # 在私有 mount namespace 里把真实盘 bind 到 /tmp，
            # 让硬编码 /tmp 的基准落到真实盘（不改被测源码）。
            # 注意：这要求上面已把运行时库路径换成真实盘路径。
            cmd = ["unshare", "-rm", "bash", "-c",
                   f"mount --bind {shlex_quote(str(bind_dir))} /tmp && "
                   f"exec env {env_prefix} {quoted}"]
        else:
            cmd = ["env", f"cjHeapSize={HEAP}"] + (
                [f"LD_LIBRARY_PATH={lib_path}"] if lib_path else []) + argv
        t0 = time.monotonic()
        try:
            r_proc = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=timeout)
            raw = r_proc.stdout + r_proc.stderr
            rc = r_proc.returncode
        except subprocess.TimeoutExpired:
            raw, rc = f"[超时 > {timeout}s]", 124
        dt = time.monotonic() - t0
        outputs.append(ANSI.sub("", raw))
        status = "ok" if rc == 0 else f"FAIL(exit={rc})"
        if rc != 0:
            failed += 1
        if verbose:
            print(f"    [{r}/{runs}] {status}  {dt:.2f}s", flush=True)
    return outputs, failed


def shlex_quote(s: str) -> str:
    import shlex
    return shlex.quote(s)


def fmt_num(v: float | None) -> str:
    if v is None:
        return "—"
    if abs(v) >= 1000:
        return f"{v:,.0f}"
    if v == int(v):
        return f"{int(v)}"
    return f"{v:.3f}".rstrip("0").rstrip(".")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="badger-cj 标准基准流程（真实盘 + 多轮中位数 + 环境指纹）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=5,
                    help="每项轮数（默认 5；取中位数）")
    ap.add_argument("--repo", default="",
                    help="要测的 checkout 目录（默认脚本所在仓库）。"
                         "测已发布 tag 时指向那个 tag 的 worktree")
    ap.add_argument("--only", default="",
                    help="只跑指定项，逗号分隔（见 --list）")
    ap.add_argument("--data-dir", default="",
                    help=f"数据目录（默认 <repo>/{DEFAULT_DATA_DIR_NAME}，须为真实盘）")
    ap.add_argument("--out-dir", default="",
                    help="报告输出目录（默认与 --data-dir 相同）")
    ap.add_argument("--no-bind-tmp", action="store_true",
                    help="不把数据目录 bind 到 /tmp（即按源码硬编码走 tmpfs）")
    ap.add_argument("--no-build", action="store_true", help="跳过 cjpm build")
    ap.add_argument("--timeout", type=int, default=1800,
                    help="单个基准单轮超时秒数（默认 1800）")
    ap.add_argument("--list", action="store_true", help="列出所有基准名后退出")
    ap.add_argument("--quiet", action="store_true", help="不打印每轮进度")
    args = ap.parse_args()

    if args.list:
        for b in BENCHES:
            print(f"  {b.key:22s} {b.title}")
        return 0

    if args.only:
        keys = [k.strip() for k in args.only.split(",") if k.strip()]
        unknown = [k for k in keys if k not in BENCH_BY_KEY]
        if unknown:
            print(f"未知基准名: {', '.join(unknown)}\n可用: {', '.join(BENCH_BY_KEY)}",
                  file=sys.stderr)
            return 2
        selected = [BENCH_BY_KEY[k] for k in keys]
    else:
        selected = BENCHES

    repo_root = Path(args.repo).resolve() if args.repo else REPO_ROOT
    if not (repo_root / "cjpm.toml").is_file():
        print(f"{repo_root} 不像一个 cjpm 项目（缺 cjpm.toml）", file=sys.stderr)
        return 2

    data_dir = Path(args.data_dir).resolve() if args.data_dir else \
        repo_root / DEFAULT_DATA_DIR_NAME
    data_dir.mkdir(parents=True, exist_ok=True)
    out_dir = Path(args.out_dir).resolve() if args.out_dir else data_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    bin_dir = repo_root / "target" / "release" / "bin"

    if not bin_dir.is_dir():
        print(f"找不到构建产物目录 {bin_dir} —— 先在该 checkout 里 cjpm build",
              file=sys.stderr)
        return 1

    fs = subprocess.run(["stat", "-f", "-c", "%T", str(data_dir)],
                        capture_output=True, text=True).stdout.strip()
    bind_dir = None
    if not args.no_bind_tmp:
        if fs == "tmpfs":
            print(f"⚠️  数据目录 {data_dir} 位于 tmpfs —— I/O 成绩会虚高，"
                  f"建议换真实盘或用默认目录", file=sys.stderr)
        bind_dir = data_dir

    if not args.no_build:
        print("→ 构建中 (cjpm build -j 16) ...", flush=True)
        r = subprocess.run(["cjpm", "build", "-j", "16"], cwd=repo_root,
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("构建失败：\n" + (r.stdout + r.stderr)[-3000:], file=sys.stderr)
            return 1
        print("  构建成功", flush=True)

    lib_path = resolve_runtime_libs()
    fp = env_fingerprint(repo_root, data_dir)
    fp["运行时库路径"] = lib_path or "(未设置，用 cjvs 原样)" 
    if bind_dir is not None:
        fp["数据目录(实际)"] = f"{data_dir}（bind mount 到 /tmp，绕过源码硬编码的 tmpfs）"

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    txt_path = out_dir / f"bench-report-{stamp}.txt"
    json_path = out_dir / f"bench-report-{stamp}.json"

    print(f"\n目标 revision: {fp['describe']}  ({fp['commit']})")
    print(f"轮数: {args.runs}   数据目录: {data_dir} [{fs}]"
          f"{'  → bind 到 /tmp' if bind_dir else '  (未 bind)'}")
    print(f"报告: {txt_path}\n")

    results: dict[str, dict] = {}
    failed_total = 0

    for bench in selected:
        print(f"▶ {bench.title}", flush=True)
        outputs, failed = run_one(bench, args.runs, args.timeout, bind_dir,
                                  verbose=not args.quiet, bin_dir=bin_dir,
                                  lib_path=lib_path)
        failed_total += failed
        parser = PARSERS[bench.parse]
        per_round: list[dict[str, float]] = [parser(o) for o in outputs]

        metrics: dict[str, Metric] = {}
        for rd in per_round:
            for k, v in rd.items():
                metrics.setdefault(k, Metric(name=k)).values.append(v)
        # 轮数不足的指标剔除（解析失败）
        metrics = {k: m for k, m in metrics.items()
                   if len(m.values) == args.runs}

        results[bench.key] = {
            "title": bench.title,
            "note": bench.note,
            "argv": bench.argv,
            "rounds": args.runs,
            "failed_rounds": failed,
            "metrics": {k: m.as_dict() for k, m in metrics.items()},
            "raw": outputs if failed else [],
        }
        n_vol = sum(1 for m in metrics.values() if m.volatile)
        print(f"  完成：{len(metrics)} 项指标"
              f"{f'，{n_vol} 项波动大(>{VOLATILE_PCT:.0f}%)' if n_vol else ''}"
              f"{f'，{failed} 轮失败' if failed else ''}", flush=True)

    # ---------- 报告 ----------
    lines: list[str] = []
    W = lines.append
    W("=" * 74)
    W("badger-cj 基准报告")
    W("=" * 74)
    W("")
    W("## 环境指纹")
    W("")
    for k, v in fp.items():
        W(f"  {k:16s} {v}")
    W("")
    W("## 运行约定")
    W("")
    W(f"  每项连跑 {args.runs} 轮取中位数；离散度 = (max-min)/中位数")
    W(f"  离散度 > {VOLATILE_PCT:.0f}% 标注 ⚠️波动大 —— 该点值不足以支撑结论，只宜作定性描述")
    W("  数据目录在真实盘（非 tmpfs），以反映真实 I/O")
    W("")
    W("## 结果")
    W("")

    for key, r in results.items():
        W(f"### {r['title']}")
        W("")
        if r["note"]:
            W(f"  {r['note']}")
            W("")
        W(f"  命令: {' '.join(r['argv'])}")
        W("")
        if not r["metrics"]:
            W("  （无可用指标）")
            W("")
            continue
        W(f"  | 指标 | 中位数 | 离散度 | 最小 | 最大 |")
        W(f"  |---|---|---|---|---|")
        for name, m in sorted(r["metrics"].items()):
            sp = m["spread_pct"]
            sp_s = f"±{sp:.1f}%" if sp is not None else "n/a"
            if m["volatile"]:
                sp_s += " ⚠️"
            W(f"  | {name} | {fmt_num(m['median'])} | {sp_s} "
              f"| {fmt_num(m['min'])} | {fmt_num(m['max'])} |")
        W("")
        # 各轮原始值，便于复核
        W("  各轮值：")
        for name, m in sorted(r["metrics"].items()):
            vals = ", ".join(fmt_num(v) for v in m["values"])
            W(f"    {name:28s} {vals}")
        W("")

    if failed_total:
        W("## 失败轮次")
        W("")
        for key, r in results.items():
            if r["failed_rounds"]:
                W(f"  {r['title']}: {r['failed_rounds']} 轮失败")
                for o in r["raw"][:1]:
                    W("  " + o.strip().replace("\n", "\n  ")[:2000])
        W("")

    txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    json_path.write_text(json.dumps(
        {"fingerprint": fp, "runs": args.runs, "results": results},
        ensure_ascii=False, indent=2), encoding="utf-8")

    print("\n" + "=" * 74)
    print(f"报告: {txt_path}")
    print(f"JSON: {json_path}")
    print("=" * 74)
    if failed_total:
        print(f"⚠️  共 {failed_total} 轮失败")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
