import { useEffect, useState } from 'react'

interface HealthStatus {
  ready: boolean
  ledger: number
  lag: number
}

interface MetricsData {
  pool_used: number
  pool_max: number
  rpc_error_rate: number
  sse_connections: number
}

type StatusTone = 'success' | 'warning' | 'danger'

function getStatusColor(metric: 'lag' | 'pool' | 'rpc', value: number): StatusTone {
  switch (metric) {
    case 'lag':
      if (value < 10) return 'success'
      if (value < 30) return 'warning'
      return 'danger'
    case 'pool':
      if (value < 0.7) return 'success'
      if (value < 0.9) return 'warning'
      return 'danger'
    case 'rpc':
      if (value < 0.01) return 'success'
      if (value < 0.05) return 'warning'
      return 'danger'
  }
}

function StatusIndicator({ color, label, value }: { color: StatusTone; label: string; value: string }) {
  return (
    <div className="ds-row ds-mb-4">
      <div className={`ds-status-dot ds-status-dot--${color}`} />
      <span>{label}: {value}</span>
    </div>
  )
}

export default function Status() {
  const [health, setHealth] = useState<HealthStatus | null>(null)
  const [metrics, setMetrics] = useState<MetricsData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const fetchData = async () => {
      try {
        const [healthRes, metricsRes] = await Promise.all([
          fetch('/healthz/ready'),
          fetch('/metrics'),
        ])

        if (healthRes.ok) {
          const data = await healthRes.json()
          setHealth(data)
        }

        if (metricsRes.ok) {
          const text = await metricsRes.text()
          const poolUsed = parseFloat(text.match(/pool_used (\d+\.?\d*)/)?.[1] || '0')
          const poolMax = parseFloat(text.match(/pool_max (\d+\.?\d*)/)?.[1] || '1')
          const rpcErrorRate = parseFloat(text.match(/rpc_error_rate (\d+\.?\d*)/)?.[1] || '0')
          const sseConnections = parseInt(text.match(/sse_connections (\d+)/)?.[1] || '0')

          setMetrics({
            pool_used: poolUsed,
            pool_max: poolMax,
            rpc_error_rate: rpcErrorRate,
            sse_connections: sseConnections,
          })
        }

        setLoading(false)
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to fetch status')
        setLoading(false)
      }
    }

    fetchData()
    const interval = setInterval(fetchData, 10000)
    return () => clearInterval(interval)
  }, [])

  if (loading) return <div className="ds-page">Loading status...</div>
  if (error) return <div className="ds-page ds-text-danger">Error: {error}</div>

  const poolUtilization = metrics ? (metrics.pool_used / metrics.pool_max) : 0
  const lagColor = health ? getStatusColor('lag', health.lag) : '#ccc'
  const poolColor = getStatusColor('pool', poolUtilization)
  const rpcColor = metrics ? getStatusColor('rpc', metrics.rpc_error_rate) : '#ccc'

  return (
    <div className="ds-page ds-page--medium">
      <h1>System Status</h1>
      <div className="ds-mt-8">
        <h2>Indexer Health</h2>
        {health && (
          <>
            <StatusIndicator
              color={health.ready ? 'success' : 'danger'}
              label="Status"
              value={health.ready ? 'Ready' : 'Not Ready'}
            />
            <StatusIndicator color={lagColor} label="Lag (blocks)" value={health.lag.toString()} />
            <StatusIndicator color={lagColor} label="Current Ledger" value={health.ledger.toString()} />
          </>
        )}
      </div>

      <div className="ds-mt-8">
        <h2>Database</h2>
        {metrics && (
          <StatusIndicator
            color={poolColor}
            label="Connection Pool"
            value={`${(poolUtilization * 100).toFixed(1)}% (${metrics.pool_used}/${metrics.pool_max})`}
          />
        )}
      </div>

      <div className="ds-mt-8">
        <h2>RPC</h2>
        {metrics && (
          <>
            <StatusIndicator
              color={rpcColor}
              label="Error Rate (5min)"
              value={`${(metrics.rpc_error_rate * 100).toFixed(2)}%`}
            />
            <StatusIndicator color="success" label="SSE Connections" value={metrics.sse_connections.toString()} />
          </>
        )}
      </div>
    </div>
  )
}
