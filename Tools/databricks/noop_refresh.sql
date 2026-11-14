-- Databricks notebook source
-- NOOP -> Databricks: rebuilds the NOOP tables from the CSV files the iPhone Shortcut uploads.
--
-- How it works: every upload is a NEW file in the volume (days__20261102-100000.csv, ...) and every row
-- carries `export_ts`, the moment of the export. Each table below reads ALL the files of its kind and keeps,
-- per key, the row with the newest `export_ts`. So an edited night or a corrected WOD replaces its older
-- version, and nothing is ever lost by uploading twice. Cell 1 is the one-time setup; the Job runs all the
-- cells, in order, every day.
--
-- CATALOG: this notebook uses the catalog `noop_uploads`. The name is set by the USE CATALOG line below, and it
-- is also written in the six read_files paths (a volume path is a literal text, it cannot take a variable).
-- If your catalog has a different name, use Edit > Find and replace to change `noop_uploads` everywhere
-- BEFORE the first run (and use the same name in the Shortcut URL, see README.md).
--
-- Not a medical device: these tables hold sport and sleep summaries for personal curiosity only.

USE CATALOG noop_uploads;
CREATE SCHEMA IF NOT EXISTS noop;
USE SCHEMA noop;
CREATE VOLUME IF NOT EXISTS raw;
-- Your own spellings of lifts: ('bs', 'Back Squat'). Empty at the start; see README.md, "Alzata rinominata".
CREATE TABLE IF NOT EXISTS lift_alias (alias STRING, lift STRING);

-- COMMAND ----------

-- days: one row per day (Charge, Effort, Rest, sleep, vitals, steps). Key: day.
CREATE OR REPLACE TABLE days AS
SELECT
  CAST(day AS DATE) AS day,
  CAST(export_ts AS TIMESTAMP) AS export_ts,
  source, charge, effort, rest, total_sleep_min, sleep_efficiency, deep_min, rem_min, light_min,
  disturbances, resting_hr, hrv_ms, spo2_pct, resp_rate_bpm, skin_temp_dev_c, steps, active_kcal
FROM (
  SELECT *
  FROM read_files(
    '/Volumes/noop_uploads/noop/raw/days__*.csv',
    format => 'csv',
    header => true,
    escape => '"',
    schema => 'day STRING, export_ts STRING, source STRING, charge DOUBLE, effort DOUBLE, rest DOUBLE, total_sleep_min DOUBLE, sleep_efficiency DOUBLE, deep_min DOUBLE, rem_min DOUBLE, light_min DOUBLE, disturbances INT, resting_hr INT, hrv_ms DOUBLE, spo2_pct DOUBLE, resp_rate_bpm DOUBLE, skin_temp_dev_c DOUBLE, steps INT, active_kcal DOUBLE'
  )
  QUALIFY row_number() OVER (PARTITION BY day ORDER BY export_ts DESC) = 1
) latest;

-- COMMAND ----------

-- sleeps: every sleep session, naps included. Key: session_start_ts (the detected start, which never changes,
-- so a night whose start was corrected later replaces the old row). Times are the local wall clock of the phone.
CREATE OR REPLACE TABLE sleeps AS
SELECT
  session_start_ts,
  CAST(export_ts AS TIMESTAMP) AS export_ts,
  CAST(start_local AS TIMESTAMP_NTZ) AS start_local,
  CAST(end_local AS TIMESTAMP_NTZ) AS end_local,
  end_ts,
  CAST(wake_day AS DATE) AS wake_day,
  in_bed_min, asleep_min, efficiency, deep_min, rem_min, light_min, wake_min, resting_hr, hrv_ms, edited, source
FROM (
  SELECT *
  FROM read_files(
    '/Volumes/noop_uploads/noop/raw/sleeps__*.csv',
    format => 'csv',
    header => true,
    escape => '"',
    schema => 'session_start_ts BIGINT, export_ts STRING, start_local STRING, end_local STRING, end_ts BIGINT, wake_day STRING, in_bed_min DOUBLE, asleep_min DOUBLE, efficiency DOUBLE, deep_min DOUBLE, rem_min DOUBLE, light_min DOUBLE, wake_min DOUBLE, resting_hr INT, hrv_ms DOUBLE, edited BOOLEAN, source STRING'
  )
  QUALIFY row_number() OVER (PARTITION BY session_start_ts ORDER BY export_ts DESC) = 1
) latest;

-- COMMAND ----------

-- workouts: workouts from the strap, imports and manual entries, with minutes in each heart-rate zone
-- (empty when the strap had no heart rate for that workout). Key: workout_key (start time + sport).
CREATE OR REPLACE TABLE workouts AS
SELECT
  workout_key,
  CAST(export_ts AS TIMESTAMP) AS export_ts,
  CAST(start_local AS TIMESTAMP_NTZ) AS start_local,
  CAST(end_local AS TIMESTAMP_NTZ) AS end_local,
  start_ts, end_ts,
  CAST(day AS DATE) AS day,
  sport, duration_min, avg_hr, max_hr, kcal, strain, z1_min, z2_min, z3_min, z4_min, z5_min, source
FROM (
  SELECT *
  FROM read_files(
    '/Volumes/noop_uploads/noop/raw/workouts__*.csv',
    format => 'csv',
    header => true,
    escape => '"',
    schema => 'workout_key STRING, export_ts STRING, start_local STRING, end_local STRING, start_ts BIGINT, end_ts BIGINT, day STRING, sport STRING, duration_min DOUBLE, avg_hr INT, max_hr INT, kcal DOUBLE, strain DOUBLE, z1_min DOUBLE, z2_min DOUBLE, z3_min DOUBLE, z4_min DOUBLE, z5_min DOUBLE, source STRING'
  )
  QUALIFY row_number() OVER (PARTITION BY workout_key ORDER BY export_ts DESC) = 1
) latest;

-- COMMAND ----------

-- wods: the WODs / strength sessions you logged (no notes). Key: wod_id. The zone minutes are filled only for
-- WODs where you set the start and the end of the whole session.
CREATE OR REPLACE TABLE wods AS
SELECT
  wod_id,
  CAST(export_ts AS TIMESTAMP) AS export_ts,
  CAST(day AS DATE) AS day,
  CAST(start_local AS TIMESTAMP_NTZ) AS start_local,
  CAST(end_local AS TIMESTAMP_NTZ) AS end_local,
  title, type, format, time_cap_s, result_kind, result_seconds, result_rounds, result_reps, result_weight_kg,
  rpe, rx, z1_min, z2_min, z3_min, z4_min, z5_min
FROM (
  SELECT *
  FROM read_files(
    '/Volumes/noop_uploads/noop/raw/wods__*.csv',
    format => 'csv',
    header => true,
    escape => '"',
    schema => 'wod_id STRING, export_ts STRING, day STRING, start_local STRING, end_local STRING, title STRING, type STRING, format STRING, time_cap_s INT, result_kind STRING, result_seconds INT, result_rounds INT, result_reps INT, result_weight_kg DOUBLE, rpe DOUBLE, rx BOOLEAN, z1_min DOUBLE, z2_min DOUBLE, z3_min DOUBLE, z4_min DOUBLE, z5_min DOUBLE'
  )
  QUALIFY row_number() OVER (PARTITION BY wod_id ORDER BY export_ts DESC) = 1
) latest;

-- COMMAND ----------

-- wod_movements: the movements of each WOD with reps and loads (no notes). Key: wod_id + position. Only the
-- movements of the NEWEST version of each WOD are kept, so a movement you deleted later does not linger.
CREATE OR REPLACE TABLE wod_movements AS
SELECT
  wod_id,
  CAST(export_ts AS TIMESTAMP) AS export_ts,
  CAST(day AS DATE) AS day,
  position, movement, reps, scheme, reps_done, weight_kg, rx_weight_kg
FROM (
  SELECT *
  FROM read_files(
    '/Volumes/noop_uploads/noop/raw/wod_movements__*.csv',
    format => 'csv',
    header => true,
    escape => '"',
    schema => 'wod_id STRING, export_ts STRING, day STRING, position INT, movement STRING, reps INT, scheme STRING, reps_done INT, weight_kg DOUBLE, rx_weight_kg DOUBLE'
  )
  QUALIFY export_ts = max(export_ts) OVER (PARTITION BY wod_id)
    AND row_number() OVER (PARTITION BY wod_id, position ORDER BY export_ts DESC) = 1
) latest;

-- COMMAND ----------

-- metrics: daily values of a fixed list of sport and sleep metrics (VO2max, Rest details, zones, ...).
-- Key: day + key. Anything outside that list is never exported by NOOP.
CREATE OR REPLACE TABLE metrics AS
SELECT
  CAST(day AS DATE) AS day,
  key,
  CAST(export_ts AS TIMESTAMP) AS export_ts,
  source, value
FROM (
  SELECT *
  FROM read_files(
    '/Volumes/noop_uploads/noop/raw/metrics__*.csv',
    format => 'csv',
    header => true,
    escape => '"',
    schema => 'day STRING, key STRING, export_ts STRING, source STRING, value DOUBLE'
  )
  QUALIFY row_number() OVER (PARTITION BY day, key ORDER BY export_ts DESC) = 1
) latest;

-- COMMAND ----------

-- lifts: one row per loaded movement. `lift` is the name to group by: your lift_alias entry when there is one,
-- else the movement name tidied up (trimmed, lower-cased, single spaces, Capitalised Words).
--   reps_used  = reps done, else prescribed reps, else the B of a scheme like 5x5, else a scheme that is one
--                number ("10"). A WOD logged with a weight result is added as a 1-rep result, unless one of its
--                movements already carries that same load (the CSV logs write both, we must not count it twice).
--   est_1rm_kg = Epley estimate, weight * (1 + reps / 30), only for 1 to 10 reps and a load above 0.
--                At 1 rep the formula gives 3 percent above the lifted weight: it is an estimate, not a record.
--   volume_kg  = sets * reps * weight for a scheme like 5x5, otherwise reps_used * weight.
CREATE OR REPLACE VIEW lifts AS
WITH alias_map AS (
  SELECT regexp_replace(lower(trim(alias)), '\\s+', ' ') AS alias_key, max(lift) AS lift
  FROM lift_alias
  GROUP BY 1
),
movements AS (
  SELECT
    w.day,
    m.wod_id,
    m.position,
    'movement' AS kind,
    m.movement,
    regexp_replace(lower(trim(m.movement)), '\\s+', ' ') AS movement_key,
    m.scheme,
    m.reps,
    m.reps_done,
    m.weight_kg,
    m.rx_weight_kg,
    try_cast(regexp_extract(m.scheme, '^\\s*(\\d+)\\s*[xX×]\\s*(\\d+)\\s*$', 1) AS INT) AS scheme_sets,
    try_cast(regexp_extract(m.scheme, '^\\s*(\\d+)\\s*[xX×]\\s*(\\d+)\\s*$', 2) AS INT) AS scheme_reps,
    try_cast(regexp_extract(m.scheme, '^\\s*(\\d+)\\s*$', 1) AS INT) AS scheme_single
  FROM wod_movements m
  JOIN wods w ON w.wod_id = m.wod_id
  WHERE m.movement IS NOT NULL AND trim(m.movement) <> ''
),
results AS (
  SELECT
    w.day,
    w.wod_id,
    0 AS position,
    'wod_result' AS kind,
    w.title AS movement,
    regexp_replace(lower(trim(w.title)), '\\s+', ' ') AS movement_key,
    CAST(NULL AS STRING) AS scheme,
    CAST(NULL AS INT) AS reps,
    CAST(NULL AS INT) AS reps_done,
    w.result_weight_kg AS weight_kg,
    CAST(NULL AS DOUBLE) AS rx_weight_kg,
    CAST(NULL AS INT) AS scheme_sets,
    CAST(NULL AS INT) AS scheme_reps,
    CAST(NULL AS INT) AS scheme_single
  FROM wods w
  WHERE w.result_kind = 'weight'
    AND w.result_weight_kg > 0
    AND w.title IS NOT NULL AND trim(w.title) <> ''
    AND NOT EXISTS (
      SELECT 1 FROM wod_movements m
      WHERE m.wod_id = w.wod_id AND m.weight_kg = w.result_weight_kg
    )
),
loaded AS (
  SELECT
    u.*,
    coalesce(u.reps_done, u.reps, u.scheme_reps, u.scheme_single,
             CASE WHEN u.kind = 'wod_result' THEN 1 END) AS reps_used
  FROM (
    SELECT * FROM movements
    UNION ALL
    SELECT * FROM results
  ) u
)
SELECT
  r.day,
  r.wod_id,
  r.position,
  r.kind,
  coalesce(a.lift, initcap(r.movement_key)) AS lift,
  r.movement,
  r.scheme,
  r.reps,
  r.reps_done,
  r.reps_used,
  r.weight_kg,
  r.rx_weight_kg,
  CASE WHEN r.weight_kg > 0 AND r.reps_used BETWEEN 1 AND 10
       THEN r.weight_kg * (1 + r.reps_used / 30) END AS est_1rm_kg,
  CASE WHEN r.scheme_sets IS NOT NULL AND r.scheme_reps IS NOT NULL
       THEN r.scheme_sets * r.scheme_reps * r.weight_kg
       ELSE r.reps_used * r.weight_kg END AS volume_kg
FROM loaded r
LEFT JOIN alias_map a ON a.alias_key = r.movement_key;

-- COMMAND ----------

-- lift_progress: per lift and week (weeks start on Monday): heaviest load, best estimated 1RM, total volume.
CREATE OR REPLACE VIEW lift_progress AS
SELECT
  lift,
  CAST(date_trunc('week', day) AS DATE) AS week_start,
  max(weight_kg) AS max_weight_kg,
  max(est_1rm_kg) AS max_est_1rm_kg,
  sum(volume_kg) AS volume_kg,
  count(DISTINCT wod_id) AS sessions
FROM lifts
WHERE weight_kg > 0
GROUP BY lift, CAST(date_trunc('week', day) AS DATE);

-- COMMAND ----------

-- zones_weekly: minutes in each heart-rate zone per week (weeks start on Monday), over workouts and WODs.
-- No double counting: a workout that overlaps in time a WOD session with zones is left out and the WOD session
-- counts instead (the WOD is the span you set yourself, usually the whole class with warm-up and skill work).
CREATE OR REPLACE VIEW zones_weekly AS
WITH wod_sessions AS (
  SELECT start_local, end_local, z1_min, z2_min, z3_min, z4_min, z5_min
  FROM wods
  WHERE end_local IS NOT NULL
    AND coalesce(z1_min, z2_min, z3_min, z4_min, z5_min) IS NOT NULL
),
workout_sessions AS (
  SELECT k.start_local, k.end_local, k.z1_min, k.z2_min, k.z3_min, k.z4_min, k.z5_min
  FROM workouts k
  WHERE coalesce(k.z1_min, k.z2_min, k.z3_min, k.z4_min, k.z5_min) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM wod_sessions s
      WHERE k.start_local < s.end_local AND s.start_local < k.end_local
    )
),
sessions AS (
  SELECT * FROM wod_sessions
  UNION ALL
  SELECT * FROM workout_sessions
)
SELECT
  CAST(date_trunc('week', start_local) AS DATE) AS week_start,
  sum(z1_min) AS z1_min,
  sum(z2_min) AS z2_min,
  sum(z3_min) AS z3_min,
  sum(z4_min) AS z4_min,
  sum(z5_min) AS z5_min,
  sum(coalesce(z1_min, 0) + coalesce(z2_min, 0) + coalesce(z3_min, 0) + coalesce(z4_min, 0) + coalesce(z5_min, 0)) AS total_min,
  count(*) AS sessions
FROM sessions
GROUP BY CAST(date_trunc('week', start_local) AS DATE);

-- COMMAND ----------

-- sleep_weekly: weekly averages of the nights in `days` (weeks start on Monday).
CREATE OR REPLACE VIEW sleep_weekly AS
SELECT
  CAST(date_trunc('week', day) AS DATE) AS week_start,
  count(total_sleep_min) AS nights,
  avg(total_sleep_min) / 60 AS avg_sleep_h,
  avg(sleep_efficiency) AS avg_efficiency,
  avg(deep_min) AS avg_deep_min,
  avg(rem_min) AS avg_rem_min,
  avg(light_min) AS avg_light_min,
  avg(disturbances) AS avg_disturbances,
  avg(rest) AS avg_rest
FROM days
GROUP BY CAST(date_trunc('week', day) AS DATE);

-- COMMAND ----------

-- recovery_daily: one row per day with Charge, Effort, Rest, HRV, resting heart rate and VO2max, plus the
-- average of the last 7 days that have a value (a smooth line for the dashboard). Charge, HRV and resting
-- heart rate come from `days`; when a day has none there, the same value from `metrics` fills in.
CREATE OR REPLACE VIEW recovery_daily AS
WITH m AS (
  SELECT
    day,
    max(CASE WHEN key = 'recovery' THEN value END) AS charge_m,
    max(CASE WHEN key = 'hrv' THEN value END) AS hrv_m,
    max(CASE WHEN key = 'rhr' THEN value END) AS rhr_m,
    max(CASE WHEN key = 'vo2max_est' THEN value END) AS vo2max_est
  FROM metrics
  GROUP BY day
),
joined AS (
  SELECT
    coalesce(d.day, m.day) AS day,
    coalesce(d.charge, m.charge_m) AS charge,
    d.effort,
    d.rest,
    coalesce(d.hrv_ms, m.hrv_m) AS hrv_ms,
    coalesce(CAST(d.resting_hr AS DOUBLE), m.rhr_m) AS resting_hr,
    m.vo2max_est
  FROM days d
  FULL OUTER JOIN m ON d.day = m.day
)
SELECT
  day, charge, effort, rest, hrv_ms, resting_hr, vo2max_est,
  avg(charge) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS charge_7d,
  avg(hrv_ms) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS hrv_7d,
  avg(resting_hr) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS resting_hr_7d
FROM joined;

-- COMMAND ----------

-- vo2max: the two VO2max estimates per day (from daily life, and from workouts).
CREATE OR REPLACE VIEW vo2max AS
SELECT
  day,
  max(CASE WHEN key = 'vo2max_est' THEN value END) AS vo2max_est,
  max(CASE WHEN key = 'vo2max_exercise' THEN value END) AS vo2max_exercise
FROM metrics
WHERE key IN ('vo2max_est', 'vo2max_exercise')
GROUP BY day;

-- COMMAND ----------

-- glucose: daily glucose, insulin and carbohydrate summaries (from Apple Health, where Loop writes them). NOOP
-- uploads these files ONLY when "Include glucose and insulin" is on in the Shortcut; without them this table is
-- simply empty (read_files returns no rows when no file matches). Key: day + key.
CREATE OR REPLACE TABLE glucose AS
SELECT
  CAST(day AS DATE) AS day,
  key,
  CAST(export_ts AS TIMESTAMP) AS export_ts,
  source, value
FROM (
  SELECT *
  FROM read_files(
    '/Volumes/noop_uploads/noop/raw/glucose__*.csv',
    format => 'csv',
    header => true,
    escape => '"',
    schema => 'day STRING, key STRING, export_ts STRING, source STRING, value DOUBLE'
  )
  QUALIFY row_number() OVER (PARTITION BY day, key ORDER BY export_ts DESC) = 1
) latest;

-- COMMAND ----------

-- glucose_daily: one row per day. Glucose in mg/dL; the bands are the international consensus on time in range
-- (Battelino et al., Diabetes Care 2019), as % of the day's readings, with its targets in the comments:
--   tbr_severe_pct  < 54        (target under 1 %)     tbr_pct  < 70, severe included  (target under 4 %)
--   tir_pct         70-180      (target over 70 %)
--   tar_pct         > 180, very high included (target under 25 %)    tar_high_pct  > 250  (target under 5 %)
--   cv_pct          coefficient of variation (stable at or under 36 %)
-- The *_band columns split the day into five parts that add up to 100 % (for a stacked chart). Hypos are level 1-2
-- events of at least 15 minutes below 70; overnight = 00:00-06:00; post-exercise = a workout and the 2 h after it.
CREATE OR REPLACE VIEW glucose_daily AS
WITH w AS (
  SELECT
    day,
    max(CASE WHEN key = 'glucose_avg' THEN value END) AS avg_mgdl,
    max(CASE WHEN key = 'glucose_min' THEN value END) AS min_mgdl,
    max(CASE WHEN key = 'glucose_max' THEN value END) AS max_mgdl,
    max(CASE WHEN key = 'glucose_tir' THEN value END) AS tir_pct,
    max(CASE WHEN key = 'glucose_tbr' THEN value END) AS tbr_pct,
    max(CASE WHEN key = 'glucose_tbr_severe' THEN value END) AS tbr_severe_pct,
    max(CASE WHEN key = 'glucose_tar' THEN value END) AS tar_pct,
    max(CASE WHEN key = 'glucose_tar_high' THEN value END) AS tar_high_pct,
    max(CASE WHEN key = 'glucose_cv' THEN value END) AS cv_pct,
    max(CASE WHEN key = 'glucose_hypos' THEN value END) AS hypos,
    max(CASE WHEN key = 'glucose_overnight_avg' THEN value END) AS overnight_avg_mgdl,
    max(CASE WHEN key = 'glucose_overnight_min' THEN value END) AS overnight_min_mgdl,
    max(CASE WHEN key = 'glucose_postex_min' THEN value END) AS postex_min_mgdl,
    max(CASE WHEN key = 'glucose_postex_lows' THEN value END) AS postex_lows,
    max(CASE WHEN key = 'insulin_total' THEN value END) AS insulin_total_u,
    max(CASE WHEN key = 'insulin_basal' THEN value END) AS insulin_basal_u,
    max(CASE WHEN key = 'insulin_bolus' THEN value END) AS insulin_bolus_u,
    max(CASE WHEN key = 'carbs_g' THEN value END) AS carbs_g
  FROM glucose
  GROUP BY day
)
SELECT
  *,
  tbr_severe_pct AS very_low_band,
  tbr_pct - tbr_severe_pct AS low_band,
  tir_pct AS in_range_band,
  tar_pct - tar_high_pct AS high_band,
  tar_high_pct AS very_high_band
FROM w;
