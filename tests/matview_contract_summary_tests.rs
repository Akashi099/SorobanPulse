//! Issue #1442: the contract summary materialized view must be created by
//! exactly one canonical definition, with the columns the API reads and the
//! unique index required by `REFRESH MATERIALIZED VIEW CONCURRENTLY`.

use sqlx::PgPool;

#[sqlx::test(migrations = "./migrations")]
async fn only_one_contract_summary_view_exists(pool: PgPool) {
    let views: Vec<String> = sqlx::query_scalar(
        "SELECT matviewname FROM pg_matviews \
         WHERE matviewname IN ('mv_contract_summary', 'events_contract_summary') \
         ORDER BY matviewname",
    )
    .fetch_all(&pool)
    .await
    .unwrap();

    assert_eq!(views, vec!["mv_contract_summary".to_string()]);
}

#[sqlx::test(migrations = "./migrations")]
async fn canonical_view_has_expected_columns(pool: PgPool) {
    // information_schema.columns does not expose materialized view columns,
    // so read them from pg_attribute.
    let columns: Vec<String> = sqlx::query_scalar(
        "SELECT a.attname \
         FROM pg_attribute a \
         JOIN pg_class c ON c.oid = a.attrelid \
         JOIN pg_namespace n ON n.oid = c.relnamespace \
         WHERE c.relname = 'mv_contract_summary' AND n.nspname = 'public' \
           AND a.attnum > 0 AND NOT a.attisdropped \
         ORDER BY a.attnum",
    )
    .fetch_all(&pool)
    .await
    .unwrap();

    assert_eq!(
        columns,
        vec![
            "contract_id",
            "event_count",
            "first_event_timestamp",
            "latest_event_timestamp",
            "min_ledger",
            "max_ledger",
            "unique_tx_count",
            "contract_events",
            "diagnostic_events",
            "system_events",
        ]
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn canonical_view_refreshes_concurrently(pool: PgPool) {
    let contract_id = "CC23456789012345678901234567890123456789012345678901234X";

    for (timestamp, tx_hash, ledger) in [
        (
            "2026-05-28T12:00:00Z",
            "200000000000000000000000000000000000000000000000000000000000000a",
            100,
        ),
        (
            "2026-05-29T12:00:00Z",
            "200000000000000000000000000000000000000000000000000000000000000b",
            120,
        ),
    ] {
        sqlx::query(
            "INSERT INTO events (contract_id, event_type, tx_hash, ledger, timestamp, event_data)
             VALUES ($1, 'contract', $2, $3, $4::timestamptz, '{}'::jsonb)",
        )
        .bind(contract_id)
        .bind(tx_hash)
        .bind(ledger)
        .bind(timestamp)
        .execute(&pool)
        .await
        .unwrap();
    }

    sqlx::query("REFRESH MATERIALIZED VIEW CONCURRENTLY mv_contract_summary")
        .execute(&pool)
        .await
        .expect("REFRESH MATERIALIZED VIEW CONCURRENTLY must succeed on the canonical view");

    let (event_count, min_ledger, max_ledger, unique_tx_count): (i64, i64, i64, i64) =
        sqlx::query_as(
            "SELECT event_count, min_ledger, max_ledger, unique_tx_count \
             FROM mv_contract_summary WHERE contract_id = $1",
        )
        .bind(contract_id)
        .fetch_one(&pool)
        .await
        .unwrap();

    assert_eq!(event_count, 2);
    assert_eq!(min_ledger, 100);
    assert_eq!(max_ledger, 120);
    assert_eq!(unique_tx_count, 2);
}
