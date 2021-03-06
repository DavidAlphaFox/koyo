SELECT
  id, queue, job, arguments, status, priority, attempts, created_at, scheduled_at, started_at, worker_id
FROM
  koyo_jobs
WHERE
  $1 = -1 OR id < $1
ORDER BY id DESC
LIMIT 100
