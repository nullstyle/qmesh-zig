#!/usr/bin/env bash
# Chaos campaign: N qmesh-node processes with fault-injection control
# channels (see tools/chaos-design.md). Seeded schedule of crash /
# freeze / drop-burst / one-way blackhole / slow faults against a
# publishing mesh; harvests invariants at the end.
#
# Usage: tools/chaos-run.sh [minutes] [seed]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/qmesh-node
[ -x "$BIN" ] || { echo "build first: zig build"; exit 1; }

MINUTES=${1:-10}
SEED=${2:-1}
N=12
BASE=4900
CTL=5900
OUT=/tmp/qmesh-chaos
mkdir -p "$OUT"; rm -f "$OUT"/*.log "$OUT"/report.txt

ids=(48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143
c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e
dc1d0a48ff1bf15cd5ae2c4f2a338fa1baab5ae5be7da6a1f7e62364789e5777
6d36cf37f9409c27571667756307520f39c7846d9696bd16ff8a3c45c318c8d3
9e2ca08bd0ceabf513ec1352e8ad749bf676cfda55e0d451c91068c16a958663
ef531a6d6d6f198625e0051c74feb69aa9d6896e6fb64664e56554f7c95e4cb9
18cdf9b433ca8675e849879292f123810ae12e6f6feaa92bd806d85679432650
13c0cd105ea3d36e575cfee3e7eecb0fec4f1606e8d30307b7307ff5dff0172a
87f28cec0e9743ad96f90d96ae6064b27f61e9973940de3d3499b760430502df
37f9bb584bf5c6db63830b0ecc4d0a51eed1aac6656bff8af526eccafdd98ce5
b8791ed5f95d7981b8153640aa1fcee42cc8a2dd5814e113bd01db652146bdb3
dcb8a1301be134790e5e4c0a61b5bfdf8cdece75b7113a4d297f12774279abb7)
letters=(a b c d e f g h i j k l)
PIDS=()

start_node() {
  local i=$1
  local port=$((BASE + i + 1)) ctl=$((CTL + i + 1))
  local letter=${letters[$i]}
  local env_args=(QMESH_ID=${ids[$i]} "QMESH_BIND=[::1]:$port" "QMESH_CONTROL=[::1]:$ctl"
    QMESH_CERT=tests/data/node-$letter.pem QMESH_KEY=tests/data/node-$letter.key
    QMESH_CA=tests/data/ca.pem QMESH_METRICS_SECS=10 QMESH_PUBLISH_EVERY=10)
  if [ "$i" -gt 0 ]; then
    env_args+=("QMESH_JOIN=${ids[0]}:[::1]:$((BASE + 1))")
  fi
  env "${env_args[@]}" "$BIN" >> "$OUT/node-$letter.log" 2>&1 &
  PIDS[$i]=$!
}

ctl() { # node-index command...
  local i=$1; shift
  printf '%s' "$*" | nc -u -w1 "::1" $((CTL + i + 1)) >/dev/null 2>&1 || true
}

# Seed-driven xorshift stream (linear seed mixing correlated victims —
# campaign 1 hammered one node; see chaos-design.md).
RS=$SEED
nrnd() { # random in [0, $1)
  RS=$(( (RS ^ (RS << 13)) & 0x7fffffff )); RS=$(( (RS ^ (RS >> 17)) & 0x7fffffff )); RS=$(( (RS ^ (RS << 5)) & 0x7fffffff ))
  echo $(( RS % $1 ))
}

for i in $(seq 0 $((N - 1))); do start_node "$i"; sleep 0.5; done
echo "$(date +%H:%M:%S) campaign start: $N nodes, seed=$SEED, ${MINUTES}min" | tee -a "$OUT/report.txt"
sleep 30

END=$((SECONDS + MINUTES * 60))
while [ $SECONDS -lt $END ]; do
  sleep $((2 + $(nrnd 6)))
  v=$((1 + $(nrnd $((N - 1)))))          # never the seed
  cls=$(nrnd 100)
  case $((cls < 25 ? 0 : cls < 45 ? 1 : cls < 65 ? 2 : cls < 80 ? 3 : cls < 90 ? 4 : 5)) in
    0) echo "$(date +%H:%M:%S) crash node-${letters[$v]}" >> "$OUT/report.txt"
       kill -9 "${PIDS[$v]}" 2>/dev/null || true
       ( sleep $((5 + $(nrnd 25))); start_node "$v" ) & ;;
    1) echo "$(date +%H:%M:%S) freeze node-${letters[$v]} $((3 + $(nrnd 12)))s" >> "$OUT/report.txt"
       ctl "$v" "freeze $((3000 + $(nrnd 12000)))" ;;
    2) echo "$(date +%H:%M:%S) drop node-${letters[$v]} $((10 + $(nrnd 30)))%" >> "$OUT/report.txt"
       ctl "$v" "drop $((1000 + $(nrnd 3000))) both" ;;
    3) t=$(nrnd $((N - 1))); t=$((t + 1)); [ "$t" -eq "$v" ] && t=0
       echo "$(date +%H:%M:%S) blackhole node-${letters[$v]} -> ${letters[$t]} (in)" >> "$OUT/report.txt"
       ctl "$v" "bh $((BASE + t + 1)) in" ;;
    4) echo "$(date +%H:%M:%S) slow node-${letters[$v]}" >> "$OUT/report.txt"
       ctl "$v" "slow $((50 + $(nrnd 150)))" ;;
    5) echo "$(date +%H:%M:%S) clear all" >> "$OUT/report.txt"
       for i in $(seq 1 $((N - 1))); do ctl "$i" clear; done ;;
  esac
done

# Heal + settle: all faults clear, 90s for re-convergence.
for i in $(seq 0 $((N - 1))); do ctl "$i" clear; done
sleep 90

{
  echo "=== final state after heal+settle ==="
  for i in $(seq 0 $((N - 1))); do
    letter=${letters[$i]}
    rss=$(ps -o rss= -p "${PIDS[$i]}" 2>/dev/null | tr -d ' ') || rss=crashed
    last=$(grep '^metrics' "$OUT/node-$letter.log" 2>/dev/null | tail -1)
    echo "node-$letter rss=${rss}KB ${last#metrics }"
  done
  echo "=== delivery ==="
  for i in $(seq 0 $((N - 1))); do
    letter=${letters[$i]}
    printf '%s:pub=%s,del=%s ' "$letter" "$(grep -c '^published' "$OUT/node-$letter.log" 2>/dev/null || echo 0)" "$(grep -c '^broadcast' "$OUT/node-$letter.log" 2>/dev/null || echo 0)"
  done
  echo
} | tee -a "$OUT/report.txt"

for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
pkill -P $$ 2>/dev/null || true
echo "campaign complete; logs in $OUT"
