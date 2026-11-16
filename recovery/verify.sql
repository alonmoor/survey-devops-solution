-- 1. On the recovery clone: rows that existed at 10:19 but are missing in prod
--    (prod_survey_ids = ids exported from prod into a temp table)
SELECT s.id, s.object_key
FROM surveys s
LEFT JOIN prod_survey_ids p ON p.id = s.id
WHERE p.id IS NULL;

-- 2. On prod, after copying rows back: every survey must point to an existing object
--    (bucket_objects = loaded from: gcloud storage ls 'gs://survey-files-prod/**')
SELECT count(*) AS rows_without_file
FROM surveys s
LEFT JOIN bucket_objects o ON o.object_key = s.object_key
WHERE o.object_key IS NULL;          -- expected: 0
