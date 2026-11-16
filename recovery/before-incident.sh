#!/usr/bin/env bash
# Changes BEFORE an incident (proposal; names are synthetic)
# 1. Cloud SQL: PITR with 7 days of transaction logs, 14 daily backups, deletion protection
gcloud sql instances patch survey-db \
  --enable-point-in-time-recovery \
  --retained-transaction-log-days=7 \
  --retained-backups-count=14 \
  --deletion-protection
# 2. Bucket: soft delete keeps deleted and overwritten objects for 7 days
gcloud storage buckets update gs://survey-files-prod --soft-delete-duration=7d
# 3. Optional extra layer: versioning + lifecycle rule deleting noncurrent versions after 7 days
# gcloud storage buckets update gs://survey-files-prod --versioning
# 4. Audit: enable Data Access audit logs for Cloud Storage and Cloud SQL (who deleted what, when)
# 5. Least privilege: operators get read-only DB roles; writes go through reviewed scripts
