#!/usr/bin/env bash
# Sequential baseline group; one scenario timeline per run, no overlap.
# Invoke detached: setsid bash harness/batch.sh cold2:cold cold3:cold warm2:warm warm3:warm > batch.out 2>&1 &
cd /var/home/Pixel/Documents/order1886-perf-work
for spec in "$@"; do
    label=${spec%%:*}; cache=${spec##*:}
    echo "=== $label $cache $(date -Is) budget=$(cat live-budget-seconds) ==="
    bash harness/run.sh "$label" "$cache" 180 > "runs-$label.out" 2>&1 &
    bash harness/scenario.sh
    wait
    sleep 10
done
echo BATCH-DONE
