#!/usr/bin/env bash
# Local zone-outage test (kubeadm, nodes labeled as fake zones).
# Unlike a drain, nothing is announced: you hard power-off every node of one zone,
# and the script measures how long users see errors and how long Kubernetes takes
# to notice (node NotReady, endpoints removed) and to recover (pods rescheduled).
#
# Usage:  ZONE=zone-b LOAD_ON=worker3 bash k8s/test-zone-outage.sh 2>&1 | tee ~/test-zone-1.log

# ---------------------------------------------------------------------------
# Block 1: shell safety and settings
# ---------------------------------------------------------------------------
# Stop on the first error (-e), on an unset variable (-u), and if any part of a pipe fails.
set -euo pipefail
# Namespace of the application.
NS=survey
# Each setting can be overridden from the command line, e.g. ZONE=zone-a bash ...
ZONE=${ZONE:-zone-b}                  # zone to "lose"
LOAD_ON=${LOAD_ON:-worker3}           # node for the load pod; must NOT be in $ZONE
LOAD_SECONDS=${LOAD_SECONDS:-1800}    # safety limit: the load loop ends by itself after this
WATCH_SECONDS=${WATCH_SECONDS:-600}   # how long to watch after the outage (pod eviction alone takes 300 s)
# The well-known node label that holds the zone name.
ZL=topology.kubernetes.io/zone

# ---------------------------------------------------------------------------
# Block 2: progress helpers (print START / DONE with time and duration)
# ---------------------------------------------------------------------------
STEP_NO=0; STEP_NAME=""; STEP_START=0
# step "<name>" "<why>": increase the step number, remember the start time, print START.
step() {
  STEP_NO=$((STEP_NO+1)); STEP_NAME="$1"; STEP_START=$(date +%s)
  echo; echo ">>> [$(date -u +%T)] STEP $STEP_NO START: $STEP_NAME"
  # Print the reason only if one was given.
  [ -n "${2:-}" ] && echo "    why: $2"
  return 0
}
# step_done "<note>": print DONE with the duration of the step and an optional note.
step_done() {
  echo "<<< [$(date -u +%T)] STEP $STEP_NO DONE:  $STEP_NAME ($(( $(date +%s) - STEP_START ))s)${1:+ - $1}"
}
# On any exit: if the script failed, say in which step.
cleanup() {
  rc=$?
  [ "$rc" -ne 0 ] && echo "!!! [$(date -u +%T)] STEP $STEP_NO FAILED: $STEP_NAME (exit $rc)"
  return 0
}
# Run cleanup when the script ends (success, error or Ctrl+C).
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Block 3: pre-checks - the zone exists, the load pod is outside it,
#          and at least one API pod runs inside it (otherwise nothing to test)
# ---------------------------------------------------------------------------
step "Check the zone and where the API pods run" "the test needs at least one API pod in $ZONE"
# Names of all nodes that carry the label zone=$ZONE.
ZONE_NODES=$(kubectl get nodes -l "$ZL=$ZONE" -o jsonpath='{.items[*].metadata.name}')
# Stop if no node is in that zone.
[ -n "$ZONE_NODES" ] || { echo "no node has $ZL=$ZONE"; exit 1; }
# Zone of the node chosen for the load pod (dots in the label key are escaped for jsonpath).
LOAD_ZONE=$(kubectl get node "$LOAD_ON" -o jsonpath="{.metadata.labels['topology\.kubernetes\.io/zone']}")
# Stop if the load pod would die together with the zone.
[ "$LOAD_ZONE" != "$ZONE" ] || { echo "LOAD_ON=$LOAD_ON is in $ZONE; pick a node in another zone"; exit 1; }
# Show where the API pods run before the outage.
kubectl -n "$NS" get pods -l app=survey-api -o wide
# Loop: for each node of the zone, count the API pods on it and add to IN_ZONE.
IN_ZONE=0
for n in $ZONE_NODES; do
  # Pods of the API on node $n; wc -l counts the lines (one line per pod).
  c=$(kubectl -n "$NS" get pods -l app=survey-api --field-selector "spec.nodeName=$n" --no-headers 2>/dev/null | wc -l)
  IN_ZONE=$((IN_ZONE + c))
done
# Stop if the zone has no API pod: losing it would prove nothing.
# Fix hint: block the other nodes, delete one pod, so its replacement can only land in $ZONE.
[ "$IN_ZONE" -gt 0 ] || { echo "no API pod in $ZONE; cordon the nodes outside $ZONE, delete one API pod, wait for rollout status, then uncordon"; exit 1; }
step_done "zone $ZONE = $ZONE_NODES, API pods there: $IN_ZONE"

# ---------------------------------------------------------------------------
# Block 4: the load pod (simulated user), pinned to a node outside the zone
# ---------------------------------------------------------------------------
step "Create the load pod on $LOAD_ON (simulated user)" "curl the Service every 0.1 s and log FAIL/SLOW"
# Remove a load pod left from a previous run (no error if there is none).
kubectl -n "$NS" delete pod load --ignore-not-found
# Create a bare pod from the curl image. --overrides sets spec.nodeName, so the pod
# runs on $LOAD_ON without the scheduler. The text after sh -c runs INSIDE the pod.
kubectl -n "$NS" run load --image=curlimages/curl --restart=Never \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$LOAD_ON\"}}" --command -- sh -c '
  # Counters, start time and the safety end time ($LOAD_SECONDS is filled in by the host shell).
  ok=0; fail=0; slow=0; start=$(date +%s); end=$(( start + '"$LOAD_SECONDS"' ))
  # Loop: one request every 0.1 s until /tmp/stop exists or the safety time has passed.
  while [ ! -f /tmp/stop ] && [ "$(date +%s)" -lt "$end" ]; do
    # One request through the Service: 2 s limit, keep the body and append " <seconds>".
    out=$(curl -sf -m 2 -w " %{time_total}" http://survey-api/healthz/ready); rc=$?
    if [ "$rc" -eq 0 ]; then
      # Success: count it and take the duration (text after the last space).
      ok=$((ok+1)); t=${out##* }
      # Take the pod name from the JSON body, or "unknown" if the field is missing.
      case "$out" in *\"pod\":\"*) pod=${out#*\"pod\":\"}; pod=${pod%%\"*} ;; *) pod=unknown ;; esac
      # Slower than 1 s: log it with the pod that answered (awk compares decimals).
      if awk "BEGIN{exit !($t>1)}"; then slow=$((slow+1)); echo "SLOW $(date -u +%T) ${t}s pod=$pod"; fi
    # Failure: count it and log the time and the curl exit code.
    else fail=$((fail+1)); echo "FAIL $(date -u +%T) curl_exit=$rc"; fi   # 7=refused 22=HTTP>=400 28=timeout
    sleep 0.1
  done
  # Summary line, read later with kubectl logs.
  echo "ok=$ok fail=$fail slow=$slow seconds=$(( $(date +%s) - start ))"'
# Wait until the load pod runs, so the measurement starts before the outage.
kubectl -n "$NS" wait --for=condition=Ready pod/load --timeout=120s
step_done

# ---------------------------------------------------------------------------
# Block 5: the outage itself - done by hand on the VM host, then Enter marks T0
# ---------------------------------------------------------------------------
step "Zone outage: power off $ZONE_NODES" "a real failure, not a drain: no eviction, no PDB, no preStop"
echo "    -> Now HARD power off the VM(s) of: $ZONE_NODES"
echo "       (VirtualBox: Close > Power off the machine, or VBoxManage controlvm <vm> poweroff)"
# Wait for Enter from the keyboard; the value is thrown away (_).
read -r -p "    -> Press Enter right after the power-off... " _
# T0 = the moment of the outage; all later times are seconds after T0.
T0=$(date +%s)
# The load loop ends by itself after LOAD_SECONDS. If Enter came too late, nobody measures the users.
LOAD_PHASE=$(kubectl -n "$NS" get pod load -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)
[ "$LOAD_PHASE" = "Running" ] || echo "!!! WARNING: load pod is $LOAD_PHASE (its ${LOAD_SECONDS}s ended before the outage) - FAIL lines will NOT be measured; node/endpoint times are still valid"
step_done "outage started at $(date -u +%T)"

# ---------------------------------------------------------------------------
# Block 6: watch how Kubernetes detects the outage and recovers
# ---------------------------------------------------------------------------
step "Watch detection and recovery for ${WATCH_SECONDS}s" "node NotReady -> endpoints removed -> pods evicted -> new pods Ready"
echo "    +sec  zone-nodes                ready-endpoints  ready-replicas"
# Times of the three events (empty = not seen yet) and the wanted number of replicas.
T_NOTREADY=""; T_EP=""; T_RECOVERED=""; WANT=$(kubectl -n "$NS" get deploy survey-api -o jsonpath='{.spec.replicas}')
# Loop: every 5 s until WATCH_SECONDS have passed since T0, sample the cluster state.
while [ $(( $(date +%s) - T0 )) -lt "$WATCH_SECONDS" ]; do
  # Seconds since the outage.
  el=$(( $(date +%s) - T0 ))
  # Ready condition of each node in the zone: True, False or Unknown ("?" if the API did not answer).
  ns=$(kubectl get nodes -l "$ZL=$ZONE" -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status} {end}' 2>/dev/null || echo "?")
  # Number of endpoints of the Service that are ready, i.e. that receive traffic.
  ep=$(kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=survey-api \
        -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true || true)
  # Number of ready replicas of the Deployment.
  rr=$(kubectl -n "$NS" get deploy survey-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  # One table row.
  printf "    +%-4s  %-24s  %-15s  %s\n" "$el" "$ns" "$ep" "${rr:-0}"
  # Event 1: the first time no zone node is Ready=True -> Kubernetes noticed the outage.
  case "$ns" in *=True*) ;; *) [ -z "$T_NOTREADY" ] && T_NOTREADY=$el && echo "    ** node(s) marked NotReady/Unknown after ${el}s" ;; esac
  # Event 2: the first time the ready endpoints dropped by the pods of the zone -> users stop hitting dead pods.
  [ -z "$T_EP" ] && [ "$ep" -le $((WANT - IN_ZONE)) ] && T_EP=$el && echo "    ** endpoints of $ZONE removed after ${el}s (users stop hitting dead pods)"
  # Event 3: after event 2, the first time all wanted replicas are ready again -> full capacity.
  [ -n "$T_EP" ] && [ -z "$T_RECOVERED" ] && [ "${rr:-0}" -ge "$WANT" ] && [ "$ep" -ge "$WANT" ] && T_RECOVERED=$el && echo "    ** back to $WANT ready replicas after ${el}s"
  sleep 5
done
step_done

# ---------------------------------------------------------------------------
# Block 7: stop the load and show what the users experienced
# ---------------------------------------------------------------------------
step "Stop the load and show the result" "FAIL lines = time users saw errors"
# Stop the load only if it still runs (exec into a Completed pod fails and would stop the script).
if [ "$(kubectl -n "$NS" get pod load -o jsonpath='{.status.phase}')" = "Running" ]; then
  # Create /tmp/stop inside the load pod; its loop ends on the next check.
  kubectl -n "$NS" exec load -- touch /tmp/stop
  # Wait until the load pod has exited (it prints its summary line on exit).
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/load --timeout=120s
else
  echo "    load pod already finished by itself (LOAD_SECONDS=${LOAD_SECONDS}s) - check its seconds= value"
fi
# Everything the load pod printed: FAIL/SLOW lines and the summary.
kubectl -n "$NS" logs load
# Where the API pods run now (replacements, and old pods still Terminating on the dead node).
kubectl -n "$NS" get pods -l app=survey-api -o wide
step_done

# ---------------------------------------------------------------------------
# Block 8: summary of the three measured times
# ---------------------------------------------------------------------------
echo
echo "=== summary (seconds after the power-off)"
echo "    node NotReady:        ${T_NOTREADY:-not seen}"
echo "    endpoints removed:    ${T_EP:-not seen}"
echo "    full capacity again:  ${T_RECOVERED:-not seen within ${WATCH_SECONDS}s}"
# Exact times from the cluster itself (independent of when Enter was pressed):
# last kubelet heartbeat (about the real power-off) and when the node turned Unknown.
for n in $ZONE_NODES; do
  echo "    $n last heartbeat (Lease renewTime): $(kubectl -n kube-node-lease get lease "$n" -o jsonpath='{.spec.renewTime}')"
  echo "    $n Ready changed at:                 $(kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
done
echo "=== next: power the VM(s) back on, then rebalance: kubectl -n $NS rollout restart deploy/survey-api"
