-- Drill 11 (joins): the drift report as DuckDB SQL, straight off the export files.
-- Run from the 11-joins folder, with either the DuckDB CLI or the Python package:
--   duckdb < sql/drift.sql
--   python3 sql/run_sql.py        (pip install duckdb)
--
-- Note: SQL trim() strips spaces only. Use regexp_replace(x, '^\s+|\s+$', '', 'g')
-- if your data has tabs or newlines in it.

CREATE OR REPLACE TABLE jamf AS
SELECT *, upper(trim(coalesce(serial, ''))) AS skey
FROM read_csv('data/jamf_computers.csv', all_varchar = true);

CREATE OR REPLACE TABLE okta AS
SELECT *, upper(trim(coalesce(serialNumber, ''))) AS skey
FROM read_json('data/okta_devices.json');

-- Row counts and blank serials
SELECT 'jamf' AS source, count(*) AS rows, count(*) FILTER (WHERE skey = '') AS blank_serials FROM jamf
UNION ALL
SELECT 'okta', count(*), count(*) FILTER (WHERE skey = '') FROM okta;

-- Serials listed more than once after normalizing (these multiply join rows)
SELECT 'jamf' AS source, count(*) AS duplicated_serials
FROM (SELECT skey FROM jamf WHERE skey <> '' GROUP BY skey HAVING count(*) > 1)
UNION ALL
SELECT 'okta', count(*)
FROM (SELECT skey FROM okta WHERE skey <> '' GROUP BY skey HAVING count(*) > 1);

-- The drift report: a full outer join on distinct keys, labeled by which side has it
WITH j AS (SELECT DISTINCT skey FROM jamf WHERE skey <> ''),
     o AS (SELECT DISTINCT skey FROM okta WHERE skey <> '')
SELECT CASE WHEN o.skey IS NULL THEN 'jamf_only'
            WHEN j.skey IS NULL THEN 'okta_only'
            ELSE 'both' END AS status,
       count(*) AS devices
FROM j FULL OUTER JOIN o ON j.skey = o.skey
GROUP BY ALL
ORDER BY status;

-- The question you usually care about: in Jamf, missing from Okta Verify (anti-join)
SELECT count(DISTINCT j.skey) AS missing_from_okta
FROM jamf j ANTI JOIN okta o ON j.skey = o.skey
WHERE j.skey <> '';

-- What a join on raw, unnormalized serials would have claimed
SELECT count(DISTINCT j.serial) AS missing_by_raw_serial
FROM jamf j ANTI JOIN okta o ON j.serial = o.serialNumber
WHERE coalesce(j.serial, '') <> '';

-- The duplicate-key trap: a plain inner join returns more rows than devices
SELECT count(*) AS join_rows, count(DISTINCT j.skey) AS devices
FROM jamf j JOIN okta o ON j.skey = o.skey
WHERE j.skey <> '';
