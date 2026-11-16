#!/usr/bin/env bash
# Incident at 10:20 Israel time = 08:20 UTC (winter, UTC+2). Names are synthetic.
# Step 3: PITR clone to a NEW instance, one minute before the mistake (never over prod)
gcloud sql instances clone survey-db survey-db-rec-0819 \
  --point-in-time='2026-11-11T08:19:00Z'
# Step 4: list, then restore, objects soft-deleted in the incident window
gcloud storage ls --soft-deleted 'gs://survey-files-prod/**' > soft-deleted.txt
gcloud storage restore 'gs://survey-files-prod/**' \
  --deleted-after-time='2026-11-11T08:15:00Z' \
  --deleted-before-time='2026-11-11T08:40:00Z' --async
