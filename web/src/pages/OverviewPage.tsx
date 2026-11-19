import { useStatus, useEvents, useContracts } from "../api/hooks.ts";
import { cx, type CardAccent } from "../design-system";

/**
 * Landing dashboard — high-level metrics and a recent events preview.
 */
export default function OverviewPage() {
  const status = useStatus();
  const events = useEvents({ limit: 5 });
  const contracts = useContracts({ limit: 1 });

  return (
    <div>
      <div className="page-header">
        <h1>Overview</h1>
        <p>Real-time summary of the SorobanPulse indexer.</p>
      </div>

      {/* Stat cards */}
      <div className="ds-stat-grid ds-mb-6">
        <StatCard
          label="Indexer"
          value={
            status.isLoading
              ? "…"
              : (status.data?.indexing ? "Indexing" : "Paused")
          }
          sub={
            status.data ? `Ledger ${status.data.latest_ledger.toLocaleString()}` : ""
          }
          accent={status.data?.indexing ? "success" : "danger"}
        />
        <StatCard
          label="Contracts indexed"
          value={contracts.isLoading ? "…" : (contracts.data?.total.toLocaleString() ?? "–")}
        />
        <StatCard
          label="Total events"
          value={events.isLoading ? "…" : (events.data?.total.toLocaleString() ?? "–")}
        />
      </div>

      {/* Recent events preview */}
      <div className="card">
        <h2 className="ds-text-md ds-mb-3">Recent Events</h2>
        {events.isLoading && <p className="text-muted">Loading…</p>}
        {events.isError && (
          <div className="error-banner">⚠ Failed to load events</div>
        )}
        {events.data && events.data.data.length === 0 && (
          <div className="empty-state">
            <div className="empty-state__icon">📭</div>
            <p>No events yet.</p>
          </div>
        )}
        {events.data && events.data.data.length > 0 && (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Contract</th>
                  <th>Type</th>
                  <th>Ledger</th>
                  <th>Timestamp</th>
                </tr>
              </thead>
              <tbody>
                {events.data.data.map((e) => (
                  <tr key={e.id}>
                    <td className="mono" title={e.id}>{e.id.slice(0, 10)}…</td>
                    <td className="mono" title={e.contract_id}>{e.contract_id.slice(0, 12)}…</td>
                    <td>
                      <span className={`badge badge--${e.event_type}`}>{e.event_type}</span>
                    </td>
                    <td>{e.ledger.toLocaleString()}</td>
                    <td className="text-muted">{new Date(e.timestamp).toLocaleString()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

function StatCard({
  label,
  value,
  sub,
  accent,
}: {
  label: string;
  value: string;
  sub?: string;
  accent?: CardAccent;
}) {
  return (
    <div className={cx("card", "ds-card", accent && `ds-card--accent-${accent}`)}>
      <p className="text-muted ds-text-xs ds-mb-1">
        {label}
      </p>
      <p className="ds-text-2xl ds-font-bold">{value}</p>
      {sub && <p className="text-muted ds-text-xs">{sub}</p>}
    </div>
  );
}
