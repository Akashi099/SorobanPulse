-- Issue #1442: Consolidate the duplicate contract summary materialized views.
--
-- Two migrations historically created a contract summary view with different
-- definitions (`events_contract_summary` from 20260428000003 and
-- `mv_contract_summary` from 20260530000001 / 20260727000001 / 20260727000002),
-- both using IF NOT EXISTS. Only the first one actually took effect, so the
-- view's shape depended on migration history instead of the latest definition.
--
-- This migration drops both views and creates a single canonical
-- `mv_contract_summary` with the columns expected by the API and statistics
-- refresh code. The unique index on contract_id is required for
-- REFRESH MATERIALIZED VIEW CONCURRENTLY.
DROP MATERIALIZED VIEW IF EXISTS events_contract_summary;
DROP MATERIALIZED VIEW IF EXISTS mv_contract_summary;

CREATE MATERIALIZED VIEW mv_contract_summary AS
SELECT
    contract_id,
    COUNT(*)                                                        AS event_count,
    MIN(timestamp)                                                  AS first_event_timestamp,
    MAX(timestamp)                                                  AS latest_event_timestamp,
    MIN(ledger)                                                     AS min_ledger,
    MAX(ledger)                                                     AS max_ledger,
    COUNT(DISTINCT tx_hash)                                         AS unique_tx_count,
    COUNT(*) FILTER (WHERE event_type = 'contract')                 AS contract_events,
    COUNT(*) FILTER (WHERE event_type = 'diagnostic')               AS diagnostic_events,
    COUNT(*) FILTER (WHERE event_type = 'system')                   AS system_events
FROM events
GROUP BY contract_id;

-- Required by REFRESH MATERIALIZED VIEW CONCURRENTLY.
CREATE UNIQUE INDEX idx_mv_contract_summary_contract_id
    ON mv_contract_summary (contract_id);

CREATE INDEX idx_mv_contract_summary_event_count
    ON mv_contract_summary (event_count DESC);

CREATE INDEX idx_mv_contract_summary_latest_event_timestamp
    ON mv_contract_summary (latest_event_timestamp DESC);

CREATE INDEX idx_mv_contract_summary_first_event_timestamp
    ON mv_contract_summary (first_event_timestamp ASC);

-- Ensure the composite index (contract_id, ledger DESC) exists for the
-- combined contract_id + ledger range filter query pattern.
CREATE INDEX IF NOT EXISTS idx_events_contract_ledger ON events(contract_id, ledger DESC);
