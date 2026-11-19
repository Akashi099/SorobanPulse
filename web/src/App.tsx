import { Routes, Route, Link } from 'react-router-dom'
import { useState, useEffect } from 'react'
import EventExplorer from './pages/EventExplorer'
import LiveStream from './pages/LiveStream'
import Status from './pages/Status'
import AdminConsole from './pages/AdminConsole'
import { useTheme } from './context/ThemeContext'

function App() {
  const { toggleTheme, theme } = useTheme()
  const [menuOpen, setMenuOpen] = useState(false)
  const [isMobile, setIsMobile] = useState(window.innerWidth < 768)

  useEffect(() => {
    const handleResize = () => {
      setIsMobile(window.innerWidth < 768)
    }
    window.addEventListener('resize', handleResize)
    return () => window.removeEventListener('resize', handleResize)
  }, [])

  return (
    <div className="app-shell">
      <nav className="app-nav">
        <div className="ds-row ds-row--lg ds-spacer">
          {isMobile ? (
            <>
              <button
                onClick={() => setMenuOpen(!menuOpen)}
                className="app-nav__menu-button"
              >
                ☰
              </button>
              {menuOpen && (
                <div className="app-nav__menu">
                  <Link to="/" onClick={() => setMenuOpen(false)}>
                    Event Explorer
                  </Link>
                  <Link to="/live" onClick={() => setMenuOpen(false)}>
                    Live Stream
                  </Link>
                  <Link to="/status" onClick={() => setMenuOpen(false)}>
                    Status
                  </Link>
                  <Link to="/admin" onClick={() => setMenuOpen(false)}>
                    Admin
                  </Link>
                </div>
              )}
            </>
          ) : (
            <>
              <Link to="/">Event Explorer</Link>
              <Link to="/live">Live Stream</Link>
              <Link to="/status">Status</Link>
              <Link to="/admin">Admin</Link>
            </>
          )}
        </div>
        <button
          onClick={toggleTheme}
          className="app-nav__theme-button"
          title="Toggle theme"
        >
          {theme === 'light' ? '🌙' : '☀️'}
        </button>
      </nav>
      <Routes>
        <Route path="/" element={<EventExplorer />} />
        <Route path="/live" element={<LiveStream />} />
        <Route path="/status" element={<Status />} />
        <Route path="/admin" element={<AdminConsole />} />
      </Routes>
    </div>
  )
}

export default App
