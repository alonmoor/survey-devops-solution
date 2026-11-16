#!/usr/bin/env bash
# Local test (kubeadm or kind): count failed requests through the Service
# during a rollout and a node drain.
# The load runs INSIDE the cluster, so it goes through the Service like real traffic
# (kubectl port-forward would pin to one pod and break when that pod is drained).
set -euo pipefail
NS=survey
TIMEOUT=${TIMEOUT:-300s}          # raise on slow labs, e.g. TIMEOUT=1200s
LOAD_SECONDS=${LOAD_SECONDS:-900} # max load duration (the script stops it earlier)
LOAD_ON=${LOAD_ON:-}              # optional: pin the load pod to a stable node, e.g. LOAD_ON=worker3
TIMELINE=${TIMELINE:-$HOME/pods-timeline.log}  # where each API pod ran, every 5 s

# Progress output: every step prints when it starts, when it ends and how long it took.
STEP_NO=0; STEP_NAME=""; STEP_START=0; TEST_START=$(date +%s)
step() {
  STEP_NO=$((STEP_NO+1)); STEP_NAME="$1"; STEP_START=$(date +%s)
  echo
  echo ">>> [$(date -u +%T)] STEP $STEP_NO START: $STEP_NAME"
  [ -n "${2:-}" ] && echo "    why: $2"
  return 0
}
step_done() {
  echo "<<< [$(date -u +%T)] STEP $STEP_NO DONE:  $STEP_NAME ($(( $(date +%s) - STEP_START ))s)${1:+ - $1}"
}

# Always clean up, even if a step fails: stop the timeline, uncordon the drained node.
NODE=""
TL_PID=""
cleanup() {
  rc=$?
  [ "$rc" -ne 0 ] && echo "!!! [$(date -u +%T)] STEP $STEP_NO FAILED: $STEP_NAME (exit $rc) - cleaning up"
  [ -n "$TL_PID" ] && kill "$TL_PID" 2>/dev/null || true
  [ -n "$NODE" ] && kubectl uncordon "$NODE" >/dev/null 2>&1 || true
  echo "=== [$(date -u +%T)] test finished, total $(( $(date +%s) - TEST_START ))s"
}
trap cleanup EXIT

echo "=== [$(date -u +%T)] availability test: namespace=$NS timeout=$TIMEOUT load-on=${LOAD_ON:-scheduler}"

OVERRIDES=()
[ -n "$LOAD_ON" ] && OVERRIDES=(--overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$LOAD_ON\"}}")

step "Delete the load pod from a previous run" "start from a clean state"
kubectl -n "$NS" delete pod load --ignore-not-found
step_done

step "Create the load pod (simulated user)" "curl the Service every 0.1 s and log FAIL/SLOW"
kubectl -n "$NS" run load --image=curlimages/curl --restart=Never "${OVERRIDES[@]}" --command -- sh -c '
  ok=0; fail=0; slow=0; start=$(date +%s); end=$(( start + '"$LOAD_SECONDS"' ))
  while [ ! -f /tmp/stop ] && [ "$(date +%s)" -lt "$end" ]; do
    out=$(curl -sf -m 2 -w " %{time_total}" http://survey-api/healthz/ready); rc=$?
    if [ "$rc" -eq 0 ]; then
      ok=$((ok+1)); t=${out##* }
      case "$out" in *\"pod\":\"*) pod=${out#*\"pod\":\"}; pod=${pod%%\"*} ;; *) pod=unknown ;; esac
      if awk "BEGIN{exit !($t>1)}"; then slow=$((slow+1)); echo "SLOW $(date -u +%T) ${t}s pod=$pod"; fi
    else fail=$((fail+1)); echo "FAIL $(date -u +%T) curl_exit=$rc"; fi   # 7=refused 22=HTTP>=400 28=timeout
    sleep 0.1
  done
  echo "ok=$ok fail=$fail slow=$slow seconds=$(( $(date +%s) - start ))"'
step_done

step "Wait until the load pod is Ready" "the measurement must run before we break anything"
kubectl -n "$NS" wait --for=condition=Ready pod/load --timeout=120s
LOAD_NODE=$(kubectl -n "$NS" get pod load -o jsonpath='{.spec.nodeName}')
step_done "load pod runs on $LOAD_NODE"

step "Start the pod-to-node timeline in the background" "match each FAIL/SLOW time to a node later"
( while true; do
    echo "== $(date -u +%T)"
    kubectl -n "$NS" get pods -l app=survey-api -o wide --no-headers 2>&1 || true
    sleep 5
  done ) >"$TIMELINE" 2>&1 &
TL_PID=$!
step_done "writing to $TIMELINE"

step "Trigger a release: rollout restart" "Problem 1: errors during releases"
kubectl -n "$NS" rollout restart deploy/survey-api
step_done

step "Wait until the release is complete" "maxSurge 1 / maxUnavailable 0: one new pod Ready before one old pod goes"
kubectl -n "$NS" rollout status deploy/survey-api --timeout="$TIMEOUT"
step_done

step "Choose a node to drain" "a node with an API pod but not the load pod"
NODE=$(kubectl -n "$NS" get pod -l app=survey-api \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | grep -vx "$LOAD_NODE" | head -1)
step_done "chosen: $NODE"

step "Node maintenance: drain $NODE" "Problem 1: errors during node maintenance; the PDB limits evictions"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout="$TIMEOUT"
step_done

step "Wait until the evicted pods are back and Ready" "replacement pods start on other nodes"
kubectl -n "$NS" rollout status deploy/survey-api --timeout="$TIMEOUT"
step_done

step "Keep the load running 15 s in steady state" "catch late errors after the drain"
sleep 15
step_done

step "Stop the load loop" "create /tmp/stop inside the load pod"
kubectl -n "$NS" exec load -- touch /tmp/stop
step_done

step "Wait until the load pod has finished" "it prints the summary line when it exits"
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/load --timeout="$TIMEOUT"
step_done

step "End maintenance: uncordon $NODE" "the node takes new pods again"
kubectl uncordon "$NODE"
step_done

step "Show the result" "expected fail=0; FAIL/SLOW lines show when and where"
kubectl -n "$NS" logs load
step_done "pod timeline: $TIMELINE"
