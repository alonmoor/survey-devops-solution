# Survey service: reliability and delivery improvements

Solution for the GCP Cloud DevOps Engineer practical assignment.

- **Solution:** [SOLUTION.md](SOLUTION.md) (per problem: cause/risk, fix, safe implementation, verification)
- **Architecture diagram:** [diagrams/architecture.mmd](diagrams/architecture.mmd) (also rendered in SOLUTION.md)
- **Release / recovery diagram:** [diagrams/release-recovery.mmd](diagrams/release-recovery.mmd)

## Repository layout

| Path | Content |
| --- | --- |
| `k8s/api-deployment.yaml` | API Deployment, PodDisruptionBudget, Service, BackendConfig |
| `k8s/health.py` | FastAPI liveness/readiness endpoints used by the probes |
| `k8s/local-test/api-local.yaml`, `k8s/test-availability.sh` | Local availability test on kubeadm or kind (nodes labeled as 3 fake zones) |
| `k8s/test-zone-outage.sh` | Local zone-outage test: power off one "zone" worker and measure errors and recovery |
| `k8s/kind-3zones.yaml` | Optional kind cluster with 3 labeled workers |
| `recovery/` | Pre-incident settings, restore commands, consistency queries |
| `recovery/local-test/` | Local restore drill: PostgreSQL with WAL archive, point-in-time clone, versioned object store |
| `scripts/` | Build-agent diagnosis, safe cleanup, Docker settings, cleanup timer |
| `scripts/local-test/agent-*` | Local build-agent lab: Docker-in-Docker with its own small disk, fill script |
| `scripts/local-test/release-*`, `migration-lab.sh` | Local release labs: `latest` vs digest rollback, incompatible migration vs expand/contract |
| `scripts/local-test/pre-receive`, `git-policy-lab.sh` | Local stand-in for the `main` branch policies (server-side git hook) |
| `pipelines/azure-pipelines.yml` | Azure DevOps Server pipeline excerpt (immutable tag, digest, approval) |

## Running the local availability test (kubeadm)

```bash
# label workers as 3 fake zones (one label per worker)
kubectl label node <worker-1> topology.kubernetes.io/zone=zone-a
kubectl label node <worker-2> topology.kubernetes.io/zone=zone-b
kubectl label node <worker-3> topology.kubernetes.io/zone=zone-c
kubectl create namespace survey --save-config
kubectl -n survey create configmap survey-api-code --from-file=main.py=k8s/health.py
kubectl apply -f k8s/local-test/api-local.yaml
kubectl -n survey rollout status deploy/survey-api --timeout=300s
bash k8s/test-availability.sh      # expected last line: ok=<n> fail=0
```

## Time spent

<!-- Fill in your real numbers -->
| Part | Hours |
| --- | --- |
| Reading, assumptions | |
| 1. Service interruptions + zone outage | |
| 2. Backup and recovery | |
| 3. Agent disk | |
| 4. + 5. Pipeline and Git controls | |
| Diagrams, review | |
| **Total** | |

## Tested locally vs proposed

<!-- Update the Status column after you run each test yourself -->
| Item | Status | Evidence |
| --- | --- | --- |
| YAML/JSON syntax of all manifests and the pipeline; `bash -n` on all scripts | Tested | parser and `bash -n` pass |
| Rolling update and node drain with PDB on kubeadm (3 fake zones) | Tested | `k8s/test-availability.sh`: `ok=1547 fail=0` (422 s) and `ok=3276 fail=0` (505 s), each with a full rollout and a node drain |
| Zone outage (one worker = one zone powered off) | Tested | `k8s/test-zone-outage.sh`: 24 failed of 3820 requests, all inside the ~50 s detection window; full capacity again after 387–517 s |
| Point-in-time recovery of the database (PostgreSQL in kubeadm) | Tested | `recovery/local-test/pg-prod.yaml`, `pg-rec.yaml`: clone to 1 minute before the delete, 110 deleted rows copied back, a rerun inserts 0 |
| Recovery of deleted and overwritten files (S3-compatible store with versioning) | Tested | `recovery/local-test/objstore.yaml`: delete markers removed, old version copied back; `verify.sql`: 0 rows without a file, 0 files without a row |
| Build agent disk full: diagnosis, safe cleanup, builder GC | Tested | `scripts/local-test/agent-lab.yaml`, `agent-fill.sh`: 11th build failed with `no space left on device`; `scripts/agent-cleanup.sh` took the disk from 100% to 19% and a test build passed; with builder GC 15 builds passed (peak 93%) |
| Rollback with `latest` vs digest + `change-cause` | Tested | `scripts/local-test/release-*.{yaml,sh}`: with `latest`, `rollout undo` still served v2; by digest it returned v1 and `rollout history` shows each release |
| App rollback after an incompatible migration; expand/contract | Tested | `scripts/local-test/migration-lab.sh`: after a rename the old app fails (`column "comment" does not exist`); a down-migration restores v1 without data loss but breaks v2; with expand both versions work |
| Branch rules on `main` (plain git stand-in for branch policies) | Tested | `scripts/local-test/pre-receive`: direct push, force push, bad branch name and a script failing `bash -n` were rejected; `feature/*` and `hotfix/*` reached `main` only after the check passed |
| gcloud: node locations, Cloud SQL HA, PITR, clone, soft delete, restore | Proposed only | no GCP account used |
| Cleanup timer, Ops Agent disk alert | Proposed only | systemd and Cloud Monitoring are not in the lab |
| GKE BackendConfig / NEG draining, maintenance window | Proposed only | |
| Azure DevOps environment approvals, branch policies | Proposed only | |

## Assumptions

See the table in [SOLUTION.md](SOLUTION.md#assumptions). All names and data are synthetic, and
no secrets are included.

## Use of AI

I used an AI assistant (Claude) to review my approach and to draft parts of the text and the
snippets. I checked the files and ran the local tests listed above myself, and I can explain
every decision in this repository.
