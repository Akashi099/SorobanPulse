import { useStatus } from "../api/hooks.ts";

/**
 * Detailed indexer status page.
 */
export default function StatusPage() {
  const { data, isLoading, isError, dataUpdatedAt } = useStatus();

  return (
    <div>
      <div className="page-header">
        <h1>Indexer Status</h1>
        <p>Live health and progress of the SorobanPulse indexer.</p>
      </div>

      {isLoading && <p className="text-muted">Fetching status…</p>}
      {isError && <div className="error-banner">⚠ Could not reach the indexer API</div>}

      {data && (
        <div className="ds-stat-grid">
          <InfoCard label="State" value={data.indexing ? "🟢 Indexing" : "🔴 Paused"} />
          <InfoCard label="Latest Ledger" value={data.latest_ledger.toLocaleString()} />
          {dataUpdatedAt > 0 && (
            <InfoCard
              label="Last Checked"
              value={new Date(dataUpdatedAt).toLocaleTimeString()}
            />
          )}
        </div>
      )}
    </div>
  );
}

function InfoCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="card">
      <p className="text-muted ds-text-xs ds-mb-1">
        {label}
      </p>
      <p className="ds-text-lg ds-font-semibold">{value}</p>
    </div>
  );
}
