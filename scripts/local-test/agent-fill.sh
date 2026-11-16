#!/bin/sh
# Problem 3 lab: fill the build agent's small disk the way a real agent fills up,
# until a build fails with "No space left on device" (assignment line 54).
# Runs INSIDE the build-agent pod (busybox sh, no bash):
#   kubectl -n agent-lab exec -i build-agent -- sh -s < scripts/local-test/agent-fill.sh
# Every step creates one kind of space user that the diagnosis must later find and classify
# as "safe to delete" or "check first".

W=/opt/ado-agent/_work
NOW=$(date +%s)

# 1. Pipeline work folders: the agent keeps one numbered folder per pipeline (200M each).
for n in 1 2 3 4; do
  mkdir -p "$W/$n/s"
  dd if=/dev/urandom of="$W/$n/s/checkout.bin" bs=1M count=200 2>/dev/null
done
# Folders 1-3 were last used 5 days ago (cleanup candidates); folder 4 is from today (may be in use).
OLD=$(date -d "@$((NOW - 5*86400))" +%Y%m%d%H%M)
for n in 1 2 3; do
  touch -t "$OLD" "$W/$n"
done
# Leftover temp files from a job that crashed.
mkdir -p "$W/_temp"
dd if=/dev/urandom of="$W/_temp/leftover.tmp" bs=1M count=50 2>/dev/null
echo "== 1. work folders done"; df -h /disk | tail -1

# 2. Containers and volumes: some are garbage, some must NOT be deleted.
docker pull -q alpine:3.20
# A stopped test container: garbage, safe to prune.
docker run --name old-test alpine:3.20 true
# A container someone started by hand and left running, with a volume in use: do NOT delete.
docker run -d --name manual-debug -v debug-data:/data alpine:3.20 \
  sh -c 'dd if=/dev/urandom of=/data/dump bs=1M count=100 2>/dev/null; tail -f /dev/null'
# A volume no container uses, but it still holds data: review it, never prune it blindly.
docker volume create old-cache
docker run --rm -v old-cache:/data alpine:3.20 \
  sh -c 'dd if=/dev/urandom of=/data/blob bs=1M count=100 2>/dev/null'
echo "== 2. containers and volumes done"; df -h /disk | tail -1

# 3. Builds: the same tag app:latest is rebuilt with a new random 150M layer each time.
#    The old image loses its tag and becomes "dangling"; build cache grows too. Stop on the first failure.
mkdir -p /tmp/ctx
MAX=${MAX:-30}                                       # number of builds; env MAX=15 for a shorter run
i=1
while [ "$i" -le "$MAX" ]; do
  dd if=/dev/urandom of=/tmp/ctx/blob bs=1M count=150 2>/dev/null
  if ! printf 'FROM alpine:3.20\nCOPY blob /blob\n' \
       | docker build -q -t app:latest -f - /tmp/ctx > /tmp/build.log 2>&1; then
    echo "== 3. build $i FAILED:"
    tail -5 /tmp/build.log
    break
  fi
  echo "build $i ok: $(df -h /disk | tail -1)"
  i=$((i + 1))
done

echo "== final"; df -h /disk
