/* =========================================================================
   30_reconcile.sql  —  prove the pipeline did what it should
   -------------------------------------------------------------------------
   1. Every data-quality rule in the latest run vs the count the generator
      says it injected (clean.dq_expected, seeded from data/dq_injected.json).
   2. Row counts flowing through raw -> clean (+ rejected) -> model.
   Any row with result = 'FAIL' needs investigating.
   ========================================================================= */

DECLARE @run_id INT = (SELECT MAX(run_id) FROM clean.dq_run);

SELECT
    l.table_name,
    l.rule_name,
    l.action_taken,
    l.rows_affected,
    e.expected_count,
    CASE WHEN l.rows_affected = e.expected_count THEN 'PASS' ELSE 'FAIL' END AS result
FROM clean.dq_log l
LEFT JOIN clean.dq_expected e ON e.rule_name = l.rule_name
WHERE l.run_id = @run_id
ORDER BY l.dq_id;

WITH c AS (
    SELECT 'members' AS table_name,
           (SELECT COUNT(*) FROM raw.members) AS raw_rows,
           (SELECT COUNT(*) FROM raw.members)
             - (SELECT COUNT(DISTINCT member_id) FROM raw.members) AS duplicates_removed,
           0 AS rejected_rows,
           (SELECT COUNT(*) FROM clean.members) AS clean_rows,
           (SELECT COUNT(*) FROM model.dim_member WHERE is_anonymous = 0) AS model_rows
    UNION ALL SELECT 'events',
           (SELECT COUNT(*) FROM raw.events), 0, 0,
           (SELECT COUNT(*) FROM clean.events),
           (SELECT COUNT(*) FROM model.dim_event)
    UNION ALL SELECT 'attendance',
           (SELECT COUNT(*) FROM raw.attendance),
           (SELECT COUNT(*) FROM raw.attendance)
             - (SELECT COUNT(DISTINCT attendance_id) FROM raw.attendance),
           (SELECT COUNT(*) FROM clean.attendance_rejected),
           (SELECT COUNT(*) FROM clean.attendance),
           (SELECT COUNT(*) FROM model.fact_attendance)
    UNION ALL SELECT 'survey_responses',
           (SELECT COUNT(*) FROM raw.survey_responses), 0, 0,
           (SELECT COUNT(*) FROM clean.survey_responses),
           (SELECT COUNT(*) FROM model.fact_survey)
    UNION ALL SELECT 'web_sessions',
           (SELECT COUNT(*) FROM raw.web_sessions), 0,
           (SELECT COUNT(*) FROM clean.web_sessions_rejected),
           (SELECT COUNT(*) FROM clean.web_sessions),
           (SELECT COUNT(*) FROM model.fact_web_session)
)
SELECT
    table_name, raw_rows, duplicates_removed, rejected_rows, clean_rows, model_rows,
    CASE WHEN raw_rows - duplicates_removed - rejected_rows = clean_rows
          AND clean_rows = model_rows THEN 'PASS' ELSE 'FAIL' END AS result
FROM c;
