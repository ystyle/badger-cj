#!/bin/bash
# badger-cj 优雅退出端到端回归（docker stop 模拟）：
#   write（不 close；memtableSize 64KB 触发多轮运行期 flush——修复后已逐轮落盘）→
#   SIGTERM → 优雅退出 exit(0) 且 close 补落盘残余 → 重启读回 5000/5000
#   对照组（write-nosignal，无优雅退出，SIGTERM 默认终止 exit=143）：
#   修复前 0/5000 全丢；修复后找回 flush 已落盘部分（<5000）——未 flush 残余仅 WAL 缓冲仍丢失，
#   故 registerSignalShutdown 的兜底价值不变
set -u
cd "$(dirname "$0")/.."
BIN=./target/release/bin/badgercj.examples.graceful_exit
FAIL=0
for i in $(seq 1 "${1:-5}"); do
  DIR=/tmp/badger_graceful_e2e_run
  LOG=/tmp/badger_graceful_e2e.log
  rm -rf "$DIR" "$LOG"
  mkdir -p "$DIR"
  "$BIN" write "$DIR" > "$LOG" 2>&1 &
  PID=$!
  for j in $(seq 1 300); do [ -f "$DIR/ready.flag" ] && break; sleep 0.05; done
  if [ ! -f "$DIR/ready.flag" ]; then echo "run#$i: NOT READY (log: $(cat "$LOG" | tr '\n' '|'))"; kill -9 $PID 2>/dev/null; FAIL=$((FAIL+1)); continue; fi
  kill -TERM $PID          # docker stop 语义（SIGTERM）
  wait $PID
  RC=$?
  sleep 0.5                # 等进程完全退出后再启动新实例（避免同目录并发 open）
  RES=$("$BIN" read "$DIR" 2>&1 | tail -1)
  GRACEFUL=$(grep -c "closing gracefully" "$LOG")
  echo "run#$i: exit=$RC graceful=$GRACEFUL $RES"
  if [ "$RC" != "0" ] || [ "$GRACEFUL" != "1" ] || ! echo "$RES" | grep -q "FOUND: 5000/5000"; then
    FAIL=$((FAIL+1)); echo "  !! FAIL: log=$(cat "$LOG" | tr '\n' '|')"
  fi
done
echo "=== 失败 $FAIL/${1:-5} ==="
[ "$FAIL" -eq 0 ]

echo "=== 对照组：不注册优雅退出（SIGTERM 默认终止，预期丢数据）==="
DIR=/tmp/badger_graceful_nosignal
LOG=/tmp/badger_graceful_nosignal.log
rm -rf "$DIR" "$LOG"
mkdir -p "$DIR"
"$BIN" write-nosignal "$DIR" > "$LOG" 2>&1 &
PID=$!
for j in $(seq 1 300); do [ -f "$DIR/ready.flag" ] && break; sleep 0.05; done
kill -TERM $PID
wait $PID
RC=$?
sleep 0.5
RES=$("$BIN" read "$DIR" 2>&1 | tail -1)
echo "对照组: exit=$RC $RES"
FOUND_N=$(echo "$RES" | grep -oE 'FOUND: [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ "$RC" == "143" ] && [ -n "$FOUND_N" ] && [ "$FOUND_N" -lt 5000 ]; then
  echo "对照组符合预期：exit=143 且未全量落盘（找回 $FOUND_N/5000）——运行期 flush 已落盘的数据"
  echo "  不依赖 close；未 flush 的 memtable 残余仅存 WAL 缓冲，仍靠 registerSignalShutdown 兜底"
else
  echo "⚠️ 对照组异常（exit=$RC, $RES）"
  FAIL=$((FAIL+1))
fi
echo "=== 结束：失败 $FAIL/${1:-5}（主场景+对照组）==="
[ "$FAIL" -eq 0 ]
