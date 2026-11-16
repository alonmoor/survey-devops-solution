#!/usr/bin/env bash
# Read-only investigation on the build agent. Deletes nothing.
df -h / ; df -i /                                    # space AND inodes
sudo du -xhd1 / 2>/dev/null | sort -h | tail -15     # where the other ~7G is
sudo du -xhd1 /var/lib/docker 2>/dev/null | sort -h
docker system df -v                                  # images / containers / volumes / build cache
docker ps -a --format '{{.Names}} {{.Status}} {{.Size}}'
docker images --filter dangling=true -q | wc -l      # untagged leftovers from :latest rebuilds
docker buildx du 2>/dev/null | tail -5               # build cache total
sudo du -xhd1 /opt/ado-agent/_work | sort -h         # per-pipeline work folders
sudo journalctl --disk-usage
sudo du -sh /var/log /tmp /home 2>/dev/null
sudo lsof +L1 2>/dev/null | head                     # deleted files still held open
systemctl list-units 'vsts.agent*' --no-pager        # agent service
pgrep -af 'Agent.Worker'                             # exists only while a job runs
