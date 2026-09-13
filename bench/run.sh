#!/usr/bin/env bash
# Run every allocator line, sequentially, on this machine.
#
#   ./bench/run.sh                      # full: 1200s x 3 rounds x 5 lines
#   DURATION=120 ROUNDS=1 ./bench/run.sh  # smoke
set -euo pipefail

IMAGE=${IMAGE:-ruby-alloc-bench}
DURATION=${DURATION:-1200}
ROUNDS=${ROUNDS:-3}
WORKLOAD=${WORKLOAD:-rails}
THREADS=${THREADS:-5}
# --cpus is a CFS quota and does NOT change nproc, so glibc would still size
# its arena cap off every host core. --cpuset-cpus is what the allocator sees.
#
# 2 cores, measured not guessed: under the GVL, 4 cores bought 1.6% more
# requests than 1. The second core only exists so the sampler thread is not
# fighting the workers for the same CPU.
CPUSET=${CPUSET:-0-1}
MEMORY=${MEMORY:-4g}
COOLDOWN=${COOLDOWN:-30}
RESULTS=${RESULTS:-$(cd "$(dirname "$0")/.." && pwd)/results}

# label:LD_PRELOAD:extra env
LINES=(
  "glibc-default::"
  "glibc-arena2::MALLOC_ARENA_MAX=2"
  "jemalloc:/alloc/libjemalloc.so:"
  "tcmalloc:/alloc/libtcmalloc.so:"
  "mimalloc:/alloc/libmimalloc.so:"
)

mkdir -p "$RESULTS"

[ "${SKIP_BUILD:-0}" = "1" ] || docker build -t "$IMAGE" "$(dirname "$0")/.."

# Preflight: prove each LD_PRELOAD actually loaded. A silently-ignored preload
# would quietly produce five identical glibc results.
# Product names lie; /proc/stat does not. On a dedicated vCPU steal stays ~0.
# On a shared one it climbs the moment a neighbour gets busy -- and it will not
# be busy while you watch, it will be busy at 3am in the middle of round 2.
if [ -r /proc/stat ]; then
  read -r _ a b c d e f g s1 _ < /proc/stat; t1=$((a+b+c+d+e+f+g+s1))
  sleep 5
  read -r _ a b c d e f g s2 _ < /proc/stat; t2=$((a+b+c+d+e+f+g+s2))
  steal=$(awk "BEGIN{printf \"%.2f\", ($s2-$s1)*100/($t2-$t1+0.001)}")
  echo "== cpu steal: ${steal}% =="
  awk "BEGIN{exit !($steal > 1.0)}" && echo "   WARNING: shared vCPU? timing numbers will be unusable."
fi

echo "== preflight =="
for line in "${LINES[@]}"; do
  IFS=: read -r label preload extra <<<"$line"
  out=$(docker run --rm --entrypoint ruby \
    ${preload:+-e LD_PRELOAD="$preload"} ${extra:+-e "$extra"} \
    "$IMAGE" -e 'puts File.read("/proc/self/maps")' | grep -cE 'jemalloc|tcmalloc|mimalloc' || true)
  if [ -z "$preload" ]; then
    [ "$out" -eq 0 ] || { echo "FAIL $label: unexpected allocator mapped"; exit 1; }
  else
    [ "$out" -gt 0 ] || { echo "FAIL $label: $preload was not loaded"; exit 1; }
  fi
  echo "  ok $label"
done

echo "== cores: $(docker run --rm --cpuset-cpus="$CPUSET" --entrypoint nproc "$IMAGE") =="
echo "== $ROUNDS round(s) x ${#LINES[@]} lines x ${DURATION}s =="
for r in $(seq 1 "$ROUNDS"); do
  for line in "${LINES[@]}"; do
    IFS=: read -r label preload extra <<<"$line"
    csv="$RESULTS/${WORKLOAD}-${label}-r${r}.csv"
    echo "-- round $r: $label"
    docker run --rm \
      --cpuset-cpus="$CPUSET" --memory="$MEMORY" \
      -e WORKLOAD="$WORKLOAD" -e DURATION="$DURATION" -e THREADS="$THREADS" \
      -e LABEL="$label" -e OUT=/results/$(basename "$csv") \
      ${preload:+-e LD_PRELOAD="$preload"} ${extra:+-e "$extra"} \
      -v "$RESULTS:/results" \
      "$IMAGE"
    sleep "$COOLDOWN"
  done
done

ruby "$(dirname "$0")/report.rb" "$RESULTS"
