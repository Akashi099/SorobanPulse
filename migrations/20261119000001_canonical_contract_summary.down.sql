-- Rollback for Issue #1442: restore the previous (duplicate) view definitions.
DROP MATERIALIZED VIEW IF EXISTS mv_contract_summary;

-- Legacy per-contract counts view created by 20260428000003.
CREATE MATERIALIZED VIEW events_contract_summary AS
SELECT
    contract_id,
    COUNT(*)     AS event_count,
    MAX(ledger)  AS latest_ledger
FROM events
GROUP BY contract_id;

CREATE UNIQUE INDEX idx_events_contract_summary_unique
    ON events_contract_summary (contract_id);

-- Per-contract summary as left by 20260727000002.
CREATE MATERIALIZED VIEW mv_contract_summary AS
SELECT
    contract_id,
    COUNT(*)                                                        AS event_count,
    MAX(timestamp)                                                  AS latest_event_timestamp,
    MIN(timestamp)                                                  AS first_event_timestamp,
    MIN(ledger)                                                     AS min_ledger,
    MAX(ledger)                                                     AS max_ledger,
    COUNT(DISTINCT tx_hash)                                         AS unique_tx_count,
    COUNT(*) FILTER (WHERE event_type = 'contract')                 AS contract_events,
    COUNT(*) FILTER (WHERE event_type = 'diagnostic')               AS diagnostic_events,
    COUNT(*) FILTER (WHERE event_type = 'system')                   AS system_events
FROM events
GROUP BY contract_id;

CREATE UNIQUE INDEX idx_mv_contract_summary_contract_id
    ON mv_contract_summary (contract_id);

CREATE INDEX idx_mv_contract_summary_event_count
    ON mv_contract_summary (event_count DESC);

CREATE INDEX idx_mv_contract_summary_latest_event_timestamp
    ON mv_contract_summary (latest_event_timestamp DESC);

CREATE INDEX idx_mv_contract_summary_first_event_timestamp
    ON mv_contract_summary (first_event_timestamp ASC);
