import { useEffect, useState } from 'react'

interface AdminHealth {
  running: boolean
  paused: boolean
  leader: boolean
  replicas: number
}

interface LagPoint {
  time: number
  lag: number
}

const ADMIN_KEY = 'admin-key'

export default function AdminConsole() {
  const [isAuthed, setIsAuthed] = useState(false)
  const [adminKey, setAdminKey] = useState('')
  const [health, setHealth] = useState<AdminHealth | null>(null)
  const [lagData, setLagData] = useState<LagPoint[]>([])
  const [replayFrom, setReplayFrom] = useState('')
  const [replayTo, setReplayTo] = useState('')
  const [dryRun, setDryRun] = useState(false)
  const [loading, setLoading] = useState(false)
  const [message, setMessage] = useState<{ type: 'error' | 'success'; text: string } | null>(null)

  useEffect(() => {
    const stored = localStorage.getItem(ADMIN_KEY)
    if (stored) {
      setAdminKey(stored)
      setIsAuthed(true)
    }
  }, [])

  const handleAuth = (e: React.FormEvent) => {
    e.preventDefault()
    localStorage.setItem(ADMIN_KEY, adminKey)
    setIsAuthed(true)
  }

  const fetchHealth = async () => {
    try {
      const res = await fetch('/healthz/ready')
      const data = await res.json()
      setHealth({
        running: data.running,
        paused: data.paused,
        leader: data.leader,
        replicas: data.replicas || 1,
      })
    } catch (err) {
      setMessage({ type: 'error', text: 'Failed to fetch health' })
    }
  }

  useEffect(() => {
    if (!isAuthed) return
    fetchHealth()
    const interval = setInterval(fetchHealth, 5000)

    const lagInterval = setInterval(() => {
      setLagData(prev => [
        ...prev.slice(-59),
        { time: Date.now(), lag: Math.random() * 50 },
      ])
    }, 5000)

    return () => {
      clearInterval(interval)
      clearInterval(lagInterval)
    }
  }, [isAuthed])

  const handlePause = async () => {
    setLoading(true)
    try {
      const res = await fetch('/v1/admin/indexer/pause', {
        method: 'POST',
        headers: { 'X-Admin-Key': adminKey },
      })
      if (res.ok) {
        setMessage({ type: 'success', text: 'Indexer paused' })
        await fetchHealth()
      } else {
        setMessage({ type: 'error', text: 'Failed to pause indexer' })
      }
    } catch (err) {
      setMessage({ type: 'error', text: 'Error pausing indexer' })
    }
    setLoading(false)
  }

  const handleResume = async () => {
    setLoading(true)
    try {
      const res = await fetch('/v1/admin/indexer/resume', {
        method: 'POST',
        headers: { 'X-Admin-Key': adminKey },
      })
      if (res.ok) {
        setMessage({ type: 'success', text: 'Indexer resumed' })
        await fetchHealth()
      } else {
        setMessage({ type: 'error', text: 'Failed to resume indexer' })
      }
    } catch (err) {
      setMessage({ type: 'error', text: 'Error resuming indexer' })
    }
    setLoading(false)
  }

  const handleReplay = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    try {
      const res = await fetch('/v1/admin/indexer/replay', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Admin-Key': adminKey,
        },
        body: JSON.stringify({
          from_ledger: parseInt(replayFrom),
          to_ledger: parseInt(replayTo),
          dry_run: dryRun,
        }),
      })
      if (res.ok) {
        setMessage({ type: 'success', text: 'Replay triggered' })
        setReplayFrom('')
        setReplayTo('')
      } else {
        setMessage({ type: 'error', text: 'Failed to trigger replay' })
      }
    } catch (err) {
      setMessage({ type: 'error', text: 'Error triggering replay' })
    }
    setLoading(false)
  }

  if (!isAuthed) {
    return (
      <div className="ds-page ds-page--narrow">
        <h1>Admin Console</h1>
        <form onSubmit={handleAuth}>
          <input
            type="password"
            placeholder="Admin Key"
            value={adminKey}
            onChange={e => setAdminKey(e.target.value)}
            className="ds-w-full ds-mb-4"
            required
          />
          <button type="submit" className="ds-button ds-button--primary ds-button--block">
            Authenticate
          </button>
        </form>
      </div>
    )
  }

  return (
    <div className="ds-page ds-page--wide">
      <h1>Admin Console</h1>

      {message && (
        <div className={`ds-alert ds-alert--${message.type === 'error' ? 'danger' : 'success'}`}>
          {message.text}
        </div>
      )}

      <div className="ds-grid-2 ds-mt-8">
        <div>
          <h2>Indexer Control</h2>
          {health && (
            <>
              <p>Status: <strong>{health.paused ? 'Paused' : health.running ? 'Running' : 'Stopped'}</strong></p>
              <p>Role: <strong>{health.leader ? 'Leader' : 'Standby'}</strong></p>
              <p>Replicas: <strong>{health.replicas}</strong></p>
              <div className="ds-row ds-mt-4">
                <button onClick={handlePause} disabled={loading || health.paused}>
                  Pause
                </button>
                <button onClick={handleResume} disabled={loading || !health.paused}>
                  Resume
                </button>
              </div>
            </>
          )}
        </div>

        <div>
          <h2>Replay Trigger</h2>
          <form onSubmit={handleReplay}>
            <input
              type="number"
              placeholder="From Ledger"
              value={replayFrom}
              onChange={e => setReplayFrom(e.target.value)}
              className="ds-w-full ds-mb-2"
              required
            />
            <input
              type="number"
              placeholder="To Ledger"
              value={replayTo}
              onChange={e => setReplayTo(e.target.value)}
              className="ds-w-full ds-mb-2"
              required
            />
            <label className="ds-row ds-mb-4">
              <input
                type="checkbox"
                checked={dryRun}
                onChange={e => setDryRun(e.target.checked)}
                
              />
              Dry Run
            </label>
            <button type="submit" disabled={loading} className="ds-button ds-button--primary ds-button--block">
              Trigger Replay
            </button>
          </form>
        </div>
      </div>

      {lagData.length > 0 && (
        <div className="ds-mt-8">
          <h2>Lag Time Series (last 5 min)</h2>
          <svg
            width="100%"
            height="200"
            className="ds-bordered ds-mt-4"
          >
            {lagData.map((point, i) => {
              const x = (i / lagData.length) * 100
              const y = 100 - ((point.lag / 50) * 100)
              return (
                <circle
                  key={i}
                  cx={`${x}%`}
                  cy={`${y}%`}
                  r="3"
                  fill="#3b82f6"
                />
              )
            })}
          </svg>
        </div>
      )}
    </div>
  )
}
