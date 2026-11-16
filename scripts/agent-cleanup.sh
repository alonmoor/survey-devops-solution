#!/usr/bin/env bash
# Safe recovery. Run only after the agent is disabled in the pool (Azure DevOps UI).
# Tested in the local lab (agent-lab pod, busybox sh): MNT=/disk points it at the lab's small disk.
set -euo pipefail
MNT=${MNT:-/}                                        # the filesystem that is full
WORK=/opt/ado-agent/_work
use() { df -P "$MNT" | awk 'NR==2 {sub("%", "", $5); print $5}'; }   # Use% as a plain number

# 1. Nothing may build while we clean: in the lab a second build refilled the disk during cleanup.
if pgrep -f 'Agent.Worker' >/dev/null; then echo "A job is running - stop here"; exit 1; fi
if pgrep -f 'docker build|buildx build' >/dev/null; then echo "A docker build is running - stop here"; exit 1; fi
SVC=""
if command -v systemctl >/dev/null; then
  SVC=$(systemctl list-units 'vsts.agent*' --no-legend | awk '{print $1}' | head -1)
fi
if [ -n "$SVC" ]; then sudo systemctl stop "$SVC"; fi   # no new job can start
echo "Before: $(use)%"

# 2. Quick small win if the disk is at 0 bytes.
if command -v journalctl >/dev/null; then sudo journalctl --vacuum-size=200M; fi

# 3. Routine cleanup: only old garbage.
docker container prune -f                            # stopped containers only
docker builder prune -f --filter until=24h           # build cache older than 24h
docker image prune -a -f --filter until=72h          # images not used by a container, older than 72h
# No 'docker volume prune' until 'docker volume ls' was reviewed.
# Never 'rm -rf /var/lib/docker/*' while Docker runs.

# 4. Old pipeline workspaces (re-created by the agent). -name, not -regex: busybox find reads
#    -regex as a basic regex where '+' is a plain character, so '.*/[0-9]+' matched nothing.
sudo find "$WORK" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -mtime +2 -exec rm -rf {} +
sudo rm -rf "$WORK"/_temp/*

# 5. Emergency step: the age filters keep fresh cache (lab: 0B freed). Still at or above the 80% alert
#    level? Remove ALL unused build cache. Safe because nothing is building; the cost is a slower next build.
if [ "$(use)" -ge 80 ]; then
  echo "Still $(use)% - removing all unused build cache"
  docker builder prune -a -f
fi

df -h "$MNT"
if [ -n "$SVC" ]; then sudo systemctl start "$SVC"; fi  # then enable the agent in the pool and run a test build
