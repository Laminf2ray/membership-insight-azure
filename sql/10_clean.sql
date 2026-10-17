/* =========================================================================
   10_clean.sql  —  raw -> clean
   -------------------------------------------------------------------------
   Turns the as-received raw tables into typed, de-duplicated, standardised
   clean tables. Every fix is flagged on the row (dq_* columns) or the row
   is moved to a *_rejected table with a reason, and every rule's row count
   is written to clean.dq_log so it can be reconciled against
   clean.dq_expected (seeded from data/dq_injected.json by run_sql.py).

   Safe to re-run: clean tables are dropped and rebuilt each time;
   clean.dq_run / clean.dq_log keep the history of every run.
   ========================================================================= */

IF SCHEMA_ID('clean') IS NULL EXEC('CREATE SCHEMA clean');
IF SCHEMA_ID('model') IS NULL EXEC('CREATE SCHEMA model');
GO

IF OBJECT_ID('clean.dq_run') IS NULL
    CREATE TABLE clean.dq_run (
        run_id  INT IDENTITY PRIMARY KEY,
        run_at  DATETIME2(0) NOT NULL
    );

IF OBJECT_ID('clean.dq_log') IS NULL
    CREATE TABLE clean.dq_log (
        dq_id          INT IDENTITY PRIMARY KEY,
        run_id         INT           NOT NULL REFERENCES clean.dq_run(run_id),
        table_name     SYSNAME       NOT NULL,
        rule_name      NVARCHAR(60)  NOT NULL,
        action_taken   NVARCHAR(200) NOT NULL,
        rows_affected  INT           NOT NULL
    );
GO

/* ---------------------------------------------------------------- DDL --- */
-- Model tables reference clean data only by value (no FKs), so clean tables
-- can be rebuilt independently of the model.
DROP TABLE IF EXISTS clean.attendance_rejected;
DROP TABLE IF EXISTS clean.attendance;
DROP TABLE IF EXISTS clean.web_sessions_rejected;
DROP TABLE IF EXISTS clean.web_sessions;
DROP TABLE IF EXISTS clean.survey_responses;
DROP TABLE IF EXISTS clean.events;
DROP TABLE IF EXISTS clean.members;
DROP TABLE IF EXISTS clean.ref_region;

CREATE TABLE clean.ref_region (
    region  NVARCHAR(50) NOT NULL PRIMARY KEY,
    nation  NVARCHAR(20) NOT NULL
);

CREATE TABLE clean.members (
    member_id               NVARCHAR(10)  NOT NULL PRIMARY KEY,
    first_name              NVARCHAR(100) NULL,
    last_name               NVARCHAR(100) NULL,
    email                   NVARCHAR(254) NULL,
    region                  NVARCHAR(50)  NOT NULL,  -- 'Unknown' when missing
    role                    NVARCHAR(50)  NULL,
    membership_type         NVARCHAR(20)  NULL,
    status                  NVARCHAR(20)  NULL,
    join_date               DATE          NULL,
    last_renewal_date       DATE          NULL,
    dq_region_missing       BIT           NOT NULL,
    dq_region_standardised  BIT           NOT NULL,
    dq_email_standardised   BIT           NOT NULL,
    dq_join_date_converted  BIT           NOT NULL,
    _loaded_at              DATETIME2(0)  NOT NULL,
    _cleaned_at             DATETIME2(0)  NOT NULL
);

CREATE TABLE clean.events (
    event_id     NVARCHAR(10)  NOT NULL PRIMARY KEY,
    title        NVARCHAR(200) NULL,
    topic        NVARCHAR(100) NULL,
    format       NVARCHAR(20)  NULL,
    event_date   DATE          NULL,
    region       NVARCHAR(50)  NULL,
    cpd_hours    DECIMAL(4,1)  NULL,
    capacity     INT           NULL,
    _loaded_at   DATETIME2(0)  NOT NULL,
    _cleaned_at  DATETIME2(0)  NOT NULL
);

CREATE TABLE clean.attendance (
    attendance_id    NVARCHAR(10) NOT NULL PRIMARY KEY,
    member_id        NVARCHAR(10) NOT NULL,
    event_id         NVARCHAR(10) NOT NULL,
    registered_date  DATE         NULL,
    attended         BIT          NOT NULL,
    feedback_score   TINYINT      NULL,
    _loaded_at       DATETIME2(0) NOT NULL,
    _cleaned_at      DATETIME2(0) NOT NULL
);

CREATE TABLE clean.attendance_rejected (
    attendance_id  NVARCHAR(400) NULL,
    member_id      NVARCHAR(400) NULL,
    event_id       NVARCHAR(400) NULL,
    reject_reason  NVARCHAR(50)  NOT NULL,
    _loaded_at     DATETIME2(0)  NOT NULL,
    _cleaned_at    DATETIME2(0)  NOT NULL
);

CREATE TABLE clean.survey_responses (
    response_id             NVARCHAR(10) NOT NULL PRIMARY KEY,
    member_id               NVARCHAR(10) NOT NULL,
    survey_date             DATE         NULL,
    satisfaction            TINYINT      NULL,  -- 1-10; NULL when missing/invalid
    likely_to_recommend     TINYINT      NULL,  -- 0-10
    dq_satisfaction_issue   NVARCHAR(20) NULL,  -- 'missing' | 'out_of_range'
    _loaded_at              DATETIME2(0) NOT NULL,
    _cleaned_at             DATETIME2(0) NOT NULL
);

CREATE TABLE clean.web_sessions (
    session_id            NVARCHAR(10) NOT NULL PRIMARY KEY,
    member_id             NVARCHAR(10) NULL,    -- NULL = anonymous visitor
    session_start         DATETIME2(0) NOT NULL,
    device                NVARCHAR(20) NULL,
    source                NVARCHAR(20) NULL,
    pages_viewed          INT          NULL,
    duration_seconds      INT          NULL,    -- NULL when negative in source
    dq_duration_negative  BIT          NOT NULL,
    _loaded_at            DATETIME2(0) NOT NULL,
    _cleaned_at           DATETIME2(0) NOT NULL
);

CREATE TABLE clean.web_sessions_rejected (
    session_id         NVARCHAR(400) NULL,
    member_id          NVARCHAR(400) NULL,
    session_start_raw  NVARCHAR(400) NULL,
    reject_reason      NVARCHAR(50)  NOT NULL,
    _loaded_at         DATETIME2(0)  NOT NULL,
    _cleaned_at        DATETIME2(0)  NOT NULL
);

INSERT INTO clean.ref_region (region, nation) VALUES
    (N'Scotland', N'Scotland'), (N'Wales', N'Wales'),
    (N'Northern Ireland', N'Northern Ireland'),
    (N'North East', N'England'), (N'North West', N'England'),
    (N'Yorkshire and the Humber', N'England'), (N'East Midlands', N'England'),
    (N'West Midlands', N'England'), (N'East of England', N'England'),
    (N'London', N'England'), (N'South East', N'England'), (N'South West', N'England');
GO

/* ------------------------------------------------------------ members --- */
-- Duplicates: keep one row per member_id.
-- Regions: trimmed + case-insensitive match to the reference list; 'NW' alias;
--          missing -> 'Unknown'. The "standardised" flag uses a case- and
--          space-sensitive comparison so 'london ' is caught (SQL Server's
--          default comparison would treat it as equal to 'London').
-- Emails: trimmed and lower-cased.
-- Join dates: ISO (yyyy-mm-dd) or UK (dd/mm/yyyy) -> DATE.
WITH d AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY _loaded_at) AS rn
    FROM raw.members
)
INSERT INTO clean.members (
    member_id, first_name, last_name, email, region, role, membership_type,
    status, join_date, last_renewal_date, dq_region_missing,
    dq_region_standardised, dq_email_standardised, dq_join_date_converted,
    _loaded_at, _cleaned_at)
SELECT
    TRIM(d.member_id),
    TRIM(d.first_name),
    TRIM(d.last_name),
    LOWER(TRIM(d.email)),
    COALESCE(rr.region,
             CASE WHEN UPPER(TRIM(d.region)) = N'NW' THEN N'North West' END,
             N'Unknown'),
    TRIM(d.role),
    TRIM(d.membership_type),
    TRIM(d.status),
    CASE WHEN d.join_date LIKE '[0-3][0-9]/[0-1][0-9]/[12][0-9][0-9][0-9]'
         THEN TRY_CONVERT(DATE, d.join_date, 103)
         ELSE TRY_CONVERT(DATE, d.join_date, 23) END,
    TRY_CONVERT(DATE, d.last_renewal_date, 23),
    CASE WHEN d.region IS NULL THEN 1 ELSE 0 END,
    CASE WHEN d.region IS NOT NULL AND NOT EXISTS (
             SELECT 1 FROM clean.ref_region x
             WHERE x.region COLLATE Latin1_General_CS_AS = d.region COLLATE Latin1_General_CS_AS
               AND DATALENGTH(x.region) = DATALENGTH(d.region))
         THEN 1 ELSE 0 END,
    CASE WHEN DATALENGTH(d.email) <> DATALENGTH(TRIM(d.email))
           OR d.email COLLATE Latin1_General_CS_AS <> LOWER(d.email) COLLATE Latin1_General_CS_AS
         THEN 1 ELSE 0 END,
    CASE WHEN d.join_date LIKE '[0-3][0-9]/[0-1][0-9]/[12][0-9][0-9][0-9]' THEN 1 ELSE 0 END,
    d._loaded_at,
    SYSUTCDATETIME()
FROM d
LEFT JOIN clean.ref_region rr ON UPPER(rr.region) = UPPER(TRIM(d.region))
WHERE d.rn = 1;
GO

/* ------------------------------------------------------------- events --- */
INSERT INTO clean.events (
    event_id, title, topic, format, event_date, region, cpd_hours, capacity,
    _loaded_at, _cleaned_at)
SELECT
    TRIM(event_id), TRIM(title), TRIM(topic), TRIM(format),
    TRY_CONVERT(DATE, event_date, 23),
    TRIM(region),
    TRY_CAST(cpd_hours AS DECIMAL(4,1)),
    TRY_CAST(capacity AS INT),
    _loaded_at, SYSUTCDATETIME()
FROM raw.events;
GO

/* --------------------------------------------------------- attendance --- */
-- Duplicates removed (one per attendance_id). Rows whose member or event
-- doesn't exist are moved to clean.attendance_rejected, not silently dropped.
WITH d AS (
    SELECT a.*,
           ROW_NUMBER() OVER (PARTITION BY a.attendance_id ORDER BY a._loaded_at) AS rn,
           CASE WHEN m.member_id IS NULL THEN 1 ELSE 0 END AS orphan_member,
           CASE WHEN e.event_id  IS NULL THEN 1 ELSE 0 END AS unknown_event
    FROM raw.attendance a
    LEFT JOIN clean.members m ON m.member_id = TRIM(a.member_id)
    LEFT JOIN clean.events  e ON e.event_id  = TRIM(a.event_id)
)
INSERT INTO clean.attendance (
    attendance_id, member_id, event_id, registered_date, attended,
    feedback_score, _loaded_at, _cleaned_at)
SELECT
    TRIM(attendance_id), TRIM(member_id), TRIM(event_id),
    TRY_CONVERT(DATE, registered_date, 23),
    CASE WHEN UPPER(TRIM(attended)) = 'Y' THEN 1 ELSE 0 END,
    TRY_CAST(TRY_CAST(feedback_score AS DECIMAL(4,1)) AS TINYINT),  -- '5.0' -> 5
    _loaded_at, SYSUTCDATETIME()
FROM d
WHERE rn = 1 AND orphan_member = 0 AND unknown_event = 0;

WITH d AS (
    SELECT a.*,
           ROW_NUMBER() OVER (PARTITION BY a.attendance_id ORDER BY a._loaded_at) AS rn,
           CASE WHEN m.member_id IS NULL THEN 1 ELSE 0 END AS orphan_member,
           CASE WHEN e.event_id  IS NULL THEN 1 ELSE 0 END AS unknown_event
    FROM raw.attendance a
    LEFT JOIN clean.members m ON m.member_id = TRIM(a.member_id)
    LEFT JOIN clean.events  e ON e.event_id  = TRIM(a.event_id)
)
INSERT INTO clean.attendance_rejected (
    attendance_id, member_id, event_id, reject_reason, _loaded_at, _cleaned_at)
SELECT attendance_id, member_id, event_id,
       CASE WHEN orphan_member = 1 THEN N'orphan_member_id' ELSE N'unknown_event_id' END,
       _loaded_at, SYSUTCDATETIME()
FROM d
WHERE rn = 1 AND (orphan_member = 1 OR unknown_event = 1);
GO

/* --------------------------------------------------- survey_responses --- */
-- Satisfaction must be 1-10. Out-of-range values become NULL (so they can't
-- distort averages) and the row is flagged; missing values are flagged too.
INSERT INTO clean.survey_responses (
    response_id, member_id, survey_date, satisfaction, likely_to_recommend,
    dq_satisfaction_issue, _loaded_at, _cleaned_at)
SELECT
    TRIM(response_id), TRIM(member_id),
    TRY_CONVERT(DATE, survey_date, 23),
    CASE WHEN TRY_CAST(satisfaction AS INT) BETWEEN 1 AND 10
         THEN TRY_CAST(satisfaction AS TINYINT) END,
    CASE WHEN TRY_CAST(likely_to_recommend AS INT) BETWEEN 0 AND 10
         THEN TRY_CAST(likely_to_recommend AS TINYINT) END,
    CASE WHEN satisfaction IS NULL THEN N'missing'
         WHEN TRY_CAST(satisfaction AS INT) IS NULL
           OR TRY_CAST(satisfaction AS INT) NOT BETWEEN 1 AND 10 THEN N'out_of_range'
    END,
    _loaded_at, SYSUTCDATETIME()
FROM raw.survey_responses;
GO

/* ------------------------------------------------------- web_sessions --- */
-- A session can't start after the data was loaded: those rows are rejected.
-- Negative durations are impossible: set to NULL and flagged.
INSERT INTO clean.web_sessions (
    session_id, member_id, session_start, device, source, pages_viewed,
    duration_seconds, dq_duration_negative, _loaded_at, _cleaned_at)
SELECT
    TRIM(session_id), TRIM(member_id),
    TRY_CONVERT(DATETIME2(0), session_start, 120),
    TRIM(device), TRIM(source),
    TRY_CAST(pages_viewed AS INT),
    CASE WHEN TRY_CAST(duration_seconds AS INT) < 0 THEN NULL
         ELSE TRY_CAST(duration_seconds AS INT) END,
    CASE WHEN TRY_CAST(duration_seconds AS INT) < 0 THEN 1 ELSE 0 END,
    _loaded_at, SYSUTCDATETIME()
FROM raw.web_sessions
WHERE TRY_CONVERT(DATETIME2(0), session_start, 120) <= _loaded_at;

INSERT INTO clean.web_sessions_rejected (
    session_id, member_id, session_start_raw, reject_reason, _loaded_at, _cleaned_at)
SELECT session_id, member_id, session_start,
       CASE WHEN TRY_CONVERT(DATETIME2(0), session_start, 120) IS NULL
            THEN N'unparsable_timestamp' ELSE N'future_dated' END,
       _loaded_at, SYSUTCDATETIME()
FROM raw.web_sessions
WHERE TRY_CONVERT(DATETIME2(0), session_start, 120) IS NULL
   OR TRY_CONVERT(DATETIME2(0), session_start, 120) > _loaded_at;
GO

/* ------------------------------------------------------------- dq log --- */
DECLARE @run_id INT;
INSERT INTO clean.dq_run (run_at) VALUES (SYSUTCDATETIME());
SET @run_id = SCOPE_IDENTITY();

INSERT INTO clean.dq_log (run_id, table_name, rule_name, action_taken, rows_affected)
SELECT @run_id, t, r, a, n FROM (
    SELECT 'members' AS t, 'members_duplicate_rows' AS r,
           'Removed duplicate rows (one kept per member_id)' AS a,
           (SELECT COUNT(*) FROM raw.members) - (SELECT COUNT(*) FROM clean.members) AS n
    UNION ALL SELECT 'members', 'members_region_missing',
           'Missing region set to ''Unknown''',
           (SELECT COUNT(*) FROM clean.members WHERE dq_region_missing = 1)
    UNION ALL SELECT 'members', 'members_region_inconsistent',
           'Region standardised to reference list (case, spaces, abbreviations)',
           (SELECT COUNT(*) FROM clean.members WHERE dq_region_standardised = 1)
    UNION ALL SELECT 'members', 'members_region_unmapped',
           'Region present but not matched to reference list (should be 0)',
           (SELECT COUNT(*) FROM clean.members WHERE region = N'Unknown' AND dq_region_missing = 0)
    UNION ALL SELECT 'members', 'members_email_messy',
           'Email trimmed and lower-cased',
           (SELECT COUNT(*) FROM clean.members WHERE dq_email_standardised = 1)
    UNION ALL SELECT 'members', 'members_join_date_ddmmyyyy',
           'Join date converted from dd/mm/yyyy',
           (SELECT COUNT(*) FROM clean.members WHERE dq_join_date_converted = 1)
    UNION ALL SELECT 'members', 'members_join_date_unparsed',
           'Join date could not be parsed (should be 0)',
           (SELECT COUNT(*) FROM clean.members WHERE join_date IS NULL)
    UNION ALL SELECT 'attendance', 'attendance_duplicate_rows',
           'Removed duplicate rows (one kept per attendance_id)',
           (SELECT COUNT(*) FROM raw.attendance)
             - (SELECT COUNT(DISTINCT attendance_id) FROM raw.attendance)
    UNION ALL SELECT 'attendance', 'attendance_orphan_member_id',
           'Rejected: member_id not found in members',
           (SELECT COUNT(*) FROM clean.attendance_rejected WHERE reject_reason = N'orphan_member_id')
    UNION ALL SELECT 'attendance', 'attendance_unknown_event_id',
           'Rejected: event_id not found in events (should be 0)',
           (SELECT COUNT(*) FROM clean.attendance_rejected WHERE reject_reason = N'unknown_event_id')
    UNION ALL SELECT 'survey_responses', 'survey_satisfaction_out_of_range',
           'Satisfaction outside 1-10 set to NULL and flagged',
           (SELECT COUNT(*) FROM clean.survey_responses WHERE dq_satisfaction_issue = N'out_of_range')
    UNION ALL SELECT 'survey_responses', 'survey_satisfaction_missing',
           'Missing satisfaction flagged',
           (SELECT COUNT(*) FROM clean.survey_responses WHERE dq_satisfaction_issue = N'missing')
    UNION ALL SELECT 'web_sessions', 'sessions_negative_duration',
           'Negative duration set to NULL and flagged',
           (SELECT COUNT(*) FROM clean.web_sessions WHERE dq_duration_negative = 1)
    UNION ALL SELECT 'web_sessions', 'sessions_future_dated',
           'Rejected: session starts after the data was loaded',
           (SELECT COUNT(*) FROM clean.web_sessions_rejected WHERE reject_reason = N'future_dated')
    UNION ALL SELECT 'web_sessions', 'sessions_unparsable_timestamp',
           'Rejected: session_start could not be parsed (should be 0)',
           (SELECT COUNT(*) FROM clean.web_sessions_rejected WHERE reject_reason = N'unparsable_timestamp')
) v;
