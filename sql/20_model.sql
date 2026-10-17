/* =========================================================================
   20_model.sql  —  clean -> model (star schema for Power BI)
   -------------------------------------------------------------------------
   Dimensions: dim_date, dim_region, dim_member, dim_event
   Facts:      fact_attendance, fact_survey, fact_web_session

   Personal data (names, emails) stays in the clean layer and is NOT copied
   into the model: reporting only needs the member key and attributes.
   Anonymous web visitors are linked to a single 'Anonymous' member (key -1).

   Safe to re-run: all model tables are dropped and rebuilt.
   ========================================================================= */

IF SCHEMA_ID('model') IS NULL EXEC('CREATE SCHEMA model');
GO

/* ---------------------------------------------------------------- DDL --- */
DROP TABLE IF EXISTS model.fact_web_session;
DROP TABLE IF EXISTS model.fact_survey;
DROP TABLE IF EXISTS model.fact_attendance;
DROP TABLE IF EXISTS model.dim_event;
DROP TABLE IF EXISTS model.dim_member;
DROP TABLE IF EXISTS model.dim_region;
DROP TABLE IF EXISTS model.dim_date;

CREATE TABLE model.dim_date (
    date_key      INT          NOT NULL PRIMARY KEY,   -- yyyymmdd
    [date]        DATE         NOT NULL UNIQUE,
    [year]        SMALLINT     NOT NULL,
    [quarter]     TINYINT      NOT NULL,
    year_quarter  CHAR(7)      NOT NULL,               -- 2026-Q3
    [month]       TINYINT      NOT NULL,
    month_name    NVARCHAR(10) NOT NULL,
    year_month    CHAR(7)      NOT NULL,               -- 2026-09
    day_of_week   NVARCHAR(10) NOT NULL,
    is_weekend    BIT          NOT NULL
);

CREATE TABLE model.dim_region (
    region_key  INT IDENTITY(1,1) PRIMARY KEY,
    region      NVARCHAR(50) NOT NULL UNIQUE,
    nation      NVARCHAR(20) NOT NULL
);

CREATE TABLE model.dim_member (
    member_key          INT IDENTITY(1,1) PRIMARY KEY,
    member_id           NVARCHAR(10) NOT NULL UNIQUE,
    region_key          INT          NOT NULL REFERENCES model.dim_region(region_key),
    role                NVARCHAR(50) NOT NULL,
    membership_type     NVARCHAR(20) NOT NULL,
    status              NVARCHAR(20) NOT NULL,
    join_date           DATE         NULL,
    join_date_key       INT          NULL REFERENCES model.dim_date(date_key),
    last_renewal_date   DATE         NULL,
    tenure_years        DECIMAL(4,1) NULL,
    days_since_renewal  INT          NULL,
    is_churned          BIT          NOT NULL,         -- Lapsed or Cancelled
    is_anonymous        BIT          NOT NULL
);

CREATE TABLE model.dim_event (
    event_key       INT IDENTITY(1,1) PRIMARY KEY,
    event_id        NVARCHAR(10)  NOT NULL UNIQUE,
    title           NVARCHAR(200) NULL,
    topic           NVARCHAR(100) NULL,
    format          NVARCHAR(20)  NULL,
    event_date      DATE          NULL,
    event_date_key  INT           NULL REFERENCES model.dim_date(date_key),
    region_key      INT           NOT NULL REFERENCES model.dim_region(region_key),
    cpd_hours       DECIMAL(4,1)  NULL,
    capacity        INT           NULL
);

CREATE TABLE model.fact_attendance (
    attendance_id        NVARCHAR(10) NOT NULL PRIMARY KEY,
    member_key           INT          NOT NULL REFERENCES model.dim_member(member_key),
    event_key            INT          NOT NULL REFERENCES model.dim_event(event_key),
    registered_date_key  INT          NULL REFERENCES model.dim_date(date_key),
    event_date_key       INT          NULL REFERENCES model.dim_date(date_key),
    attended             BIT          NOT NULL,
    feedback_score       TINYINT      NULL,
    cpd_hours_earned     DECIMAL(5,1) NOT NULL
);

CREATE TABLE model.fact_survey (
    response_id          NVARCHAR(10) NOT NULL PRIMARY KEY,
    member_key           INT          NOT NULL REFERENCES model.dim_member(member_key),
    survey_date_key      INT          NULL REFERENCES model.dim_date(date_key),
    satisfaction         TINYINT      NULL,
    likely_to_recommend  TINYINT      NULL,
    nps_group            NVARCHAR(10) NULL             -- Promoter / Passive / Detractor
);

CREATE TABLE model.fact_web_session (
    session_id        NVARCHAR(10) NOT NULL PRIMARY KEY,
    member_key        INT          NOT NULL REFERENCES model.dim_member(member_key),
    session_date_key  INT          NOT NULL REFERENCES model.dim_date(date_key),
    session_hour      TINYINT      NOT NULL,
    device            NVARCHAR(20) NULL,
    source            NVARCHAR(20) NULL,
    pages_viewed      INT          NULL,
    duration_seconds  INT          NULL
);
GO

/* ----------------------------------------------------------- dim_date --- */
WITH n AS (
    SELECT TOP (DATEDIFF(DAY, '2020-01-01', '2027-12-31') + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
), d AS (
    SELECT DATEADD(DAY, i, CAST('2020-01-01' AS DATE)) AS dt FROM n
)
INSERT INTO model.dim_date (date_key, [date], [year], [quarter], year_quarter,
                            [month], month_name, year_month, day_of_week, is_weekend)
SELECT
    CONVERT(INT, CONVERT(CHAR(8), dt, 112)),
    dt,
    YEAR(dt),
    DATEPART(QUARTER, dt),
    CONCAT(YEAR(dt), '-Q', DATEPART(QUARTER, dt)),
    MONTH(dt),
    DATENAME(MONTH, dt),
    CONVERT(CHAR(7), dt, 126),
    DATENAME(WEEKDAY, dt),
    CASE WHEN DATENAME(WEEKDAY, dt) IN ('Saturday', 'Sunday') THEN 1 ELSE 0 END
FROM d;
GO

/* --------------------------------------------------------- dim_region --- */
INSERT INTO model.dim_region (region, nation)
SELECT region, nation FROM clean.ref_region
UNION ALL SELECT N'Unknown',  N'Unknown'
UNION ALL SELECT N'National', N'UK-wide';
GO

/* --------------------------------------------------------- dim_member --- */
-- Snapshot date for tenure / renewal measures = latest renewal in the data.
DECLARE @as_of DATE = (SELECT MAX(last_renewal_date) FROM clean.members);

SET IDENTITY_INSERT model.dim_member ON;
INSERT INTO model.dim_member (member_key, member_id, region_key, role, membership_type,
                              status, is_churned, is_anonymous)
SELECT -1, N'ANON', region_key, N'Anonymous visitor', N'Anonymous', N'Anonymous', 0, 1
FROM model.dim_region WHERE region = N'Unknown';
SET IDENTITY_INSERT model.dim_member OFF;

INSERT INTO model.dim_member (member_id, region_key, role, membership_type, status,
                              join_date, join_date_key, last_renewal_date,
                              tenure_years, days_since_renewal, is_churned, is_anonymous)
SELECT
    m.member_id,
    r.region_key,
    COALESCE(m.role, N'Unknown'),
    COALESCE(m.membership_type, N'Unknown'),
    COALESCE(m.status, N'Unknown'),
    m.join_date,
    CONVERT(INT, CONVERT(CHAR(8), m.join_date, 112)),
    m.last_renewal_date,
    CAST(DATEDIFF(DAY, m.join_date, @as_of) / 365.25 AS DECIMAL(4,1)),
    DATEDIFF(DAY, m.last_renewal_date, @as_of),
    CASE WHEN m.status IN (N'Lapsed', N'Cancelled') THEN 1 ELSE 0 END,
    0
FROM clean.members m
JOIN model.dim_region r ON r.region = m.region;
GO

/* ---------------------------------------------------------- dim_event --- */
INSERT INTO model.dim_event (event_id, title, topic, format, event_date,
                             event_date_key, region_key, cpd_hours, capacity)
SELECT
    e.event_id, e.title, e.topic, e.format, e.event_date,
    CONVERT(INT, CONVERT(CHAR(8), e.event_date, 112)),
    COALESCE(r.region_key, u.region_key),
    e.cpd_hours, e.capacity
FROM clean.events e
LEFT JOIN model.dim_region r ON r.region = e.region
CROSS JOIN (SELECT region_key FROM model.dim_region WHERE region = N'Unknown') u;
GO

/* ------------------------------------------------------------- facts --- */
INSERT INTO model.fact_attendance (attendance_id, member_key, event_key,
                                   registered_date_key, event_date_key, attended,
                                   feedback_score, cpd_hours_earned)
SELECT
    a.attendance_id, m.member_key, e.event_key,
    CONVERT(INT, CONVERT(CHAR(8), a.registered_date, 112)),
    e.event_date_key,
    a.attended,
    a.feedback_score,
    CASE WHEN a.attended = 1 THEN COALESCE(e.cpd_hours, 0) ELSE 0 END
FROM clean.attendance a
JOIN model.dim_member m ON m.member_id = a.member_id
JOIN model.dim_event  e ON e.event_id  = a.event_id;

INSERT INTO model.fact_survey (response_id, member_key, survey_date_key,
                               satisfaction, likely_to_recommend, nps_group)
SELECT
    s.response_id, m.member_key,
    CONVERT(INT, CONVERT(CHAR(8), s.survey_date, 112)),
    s.satisfaction, s.likely_to_recommend,
    CASE WHEN s.likely_to_recommend >= 9 THEN N'Promoter'
         WHEN s.likely_to_recommend >= 7 THEN N'Passive'
         WHEN s.likely_to_recommend IS NOT NULL THEN N'Detractor' END
FROM clean.survey_responses s
JOIN model.dim_member m ON m.member_id = s.member_id;

INSERT INTO model.fact_web_session (session_id, member_key, session_date_key,
                                    session_hour, device, source, pages_viewed,
                                    duration_seconds)
SELECT
    w.session_id,
    COALESCE(m.member_key, -1),
    CONVERT(INT, CONVERT(CHAR(8), w.session_start, 112)),
    DATEPART(HOUR, w.session_start),
    w.device, w.source, w.pages_viewed, w.duration_seconds
FROM clean.web_sessions w
LEFT JOIN model.dim_member m ON m.member_id = w.member_id AND m.is_anonymous = 0;
