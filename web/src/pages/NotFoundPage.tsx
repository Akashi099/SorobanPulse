import { Link } from "react-router-dom";

export default function NotFoundPage() {
  return (
    <div className="empty-state ds-mt-16">
      <div className="empty-state__icon">🔭</div>
      <h1 className="ds-text-xl ds-mb-2">Page Not Found</h1>
      <p className="text-muted">That route doesn't exist.</p>
      <p className="mt-2">
        <Link to="/" className="btn btn--primary">
          ← Back to Overview
        </Link>
      </p>
    </div>
  );
}
