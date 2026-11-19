//! Issue #1351: Geospatial RPC endpoint selection.
//!
//! Each replica detects its region from `FLY_REGION` or `AWS_DEFAULT_REGION`
//! and, when `STELLAR_RPC_REGION_MAP` (a JSON object of region → RPC URL) is
//! configured, picks the RPC endpoint mapped to that region. If no map is
//! configured, the region is unknown, or the region is not in the map, the
//! configured `STELLAR_RPC_URL` is kept.

use std::collections::HashMap;

/// Env var holding the JSON region → RPC URL map.
pub const REGION_MAP_ENV: &str = "STELLAR_RPC_REGION_MAP";

/// Region env vars consulted, in priority order.
pub const REGION_ENV_VARS: [&str; 2] = ["FLY_REGION", "AWS_DEFAULT_REGION"];

/// Outcome of RPC endpoint selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegionSelection {
    /// The detected region (`"unknown"` when none was detected).
    pub region: String,
    /// The RPC URL to use.
    pub url: String,
    /// `true` when the URL came from the region map.
    pub from_region_map: bool,
}

/// Detect the current region using the supplied env lookup.
pub fn detect_region_with<F: Fn(&str) -> Option<String>>(get: F) -> Option<String> {
    REGION_ENV_VARS
        .iter()
        .filter_map(|k| get(k))
        .map(|v| v.trim().to_string())
        .find(|v| !v.is_empty())
}

/// Detect the current region from the process environment.
pub fn detect_region() -> Option<String> {
    detect_region_with(|k| std::env::var(k).ok())
}

/// Parse a region map from JSON. Returns an error string on malformed JSON.
pub fn parse_region_map(raw: &str) -> Result<HashMap<String, String>, String> {
    serde_json::from_str::<HashMap<String, String>>(raw)
        .map_err(|e| format!("{REGION_MAP_ENV} must be a JSON object of region -> URL: {e}"))
}

/// Pure selection logic: choose the URL for `region` from `map`, falling back
/// to `default_url`.
pub fn select_endpoint(
    region: Option<&str>,
    map: Option<&HashMap<String, String>>,
    default_url: &str,
) -> RegionSelection {
    let region_label = region.unwrap_or("unknown").to_string();
    if let (Some(r), Some(m)) = (region, map) {
        if let Some(url) = m.get(r).filter(|u| !u.trim().is_empty()) {
            return RegionSelection {
                region: region_label,
                url: url.trim().to_string(),
                from_region_map: true,
            };
        }
    }
    RegionSelection {
        region: region_label,
        url: default_url.to_string(),
        from_region_map: false,
    }
}

/// Resolve the RPC endpoint from the process environment and record the
/// `soroban_pulse_rpc_region` info metric.
pub fn resolve_from_env(default_url: &str) -> RegionSelection {
    let region = detect_region();
    let map = match std::env::var(REGION_MAP_ENV) {
        Ok(raw) if !raw.trim().is_empty() => match parse_region_map(&raw) {
            Ok(m) => Some(m),
            Err(e) => {
                tracing::warn!(error = %e, "Ignoring invalid {REGION_MAP_ENV}; using STELLAR_RPC_URL");
                None
            }
        },
        _ => None,
    };
    let selection = select_endpoint(region.as_deref(), map.as_ref(), default_url);
    record_metric(&selection);
    selection
}

/// Set the `soroban_pulse_rpc_region` info metric (value 1, labelled by region).
pub fn record_metric(selection: &RegionSelection) {
    metrics::gauge!(
        "soroban_pulse_rpc_region",
        "region" => selection.region.clone(),
        "source" => if selection.from_region_map { "region_map" } else { "default" },
    )
    .set(1.0);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map() -> HashMap<String, String> {
        parse_region_map(r#"{"us-east-1":"https://us.rpc.example","fra":"https://eu.rpc.example"}"#)
            .unwrap()
    }

    #[test]
    fn us_east_replica_uses_us_endpoint() {
        let m = map();
        let s = select_endpoint(Some("us-east-1"), Some(&m), "https://default");
        assert_eq!(s.url, "https://us.rpc.example");
        assert_eq!(s.region, "us-east-1");
        assert!(s.from_region_map);
    }

    #[test]
    fn falls_back_without_map() {
        let s = select_endpoint(Some("us-east-1"), None, "https://default");
        assert_eq!(s.url, "https://default");
        assert!(!s.from_region_map);
    }

    #[test]
    fn falls_back_for_unmapped_region() {
        let m = map();
        let s = select_endpoint(Some("syd"), Some(&m), "https://default");
        assert_eq!(s.url, "https://default");
    }

    #[test]
    fn falls_back_when_region_unknown() {
        let m = map();
        let s = select_endpoint(None, Some(&m), "https://default");
        assert_eq!(s.region, "unknown");
        assert_eq!(s.url, "https://default");
    }

    #[test]
    fn fly_region_takes_priority_over_aws() {
        let r = detect_region_with(|k| match k {
            "FLY_REGION" => Some("fra".into()),
            "AWS_DEFAULT_REGION" => Some("us-east-1".into()),
            _ => None,
        });
        assert_eq!(r.as_deref(), Some("fra"));
    }

    #[test]
    fn aws_region_used_when_fly_absent() {
        let r = detect_region_with(|k| (k == "AWS_DEFAULT_REGION").then(|| "us-east-1".into()));
        assert_eq!(r.as_deref(), Some("us-east-1"));
    }

    #[test]
    fn invalid_map_is_rejected() {
        assert!(parse_region_map("not json").is_err());
    }
}
