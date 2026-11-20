//! HTTP request handlers, split into per-domain modules (Issues #1239, #1240, #1241).
//!
//! | Module          | Contents                                                        |
//! |-----------------|-----------------------------------------------------------------|
//! | `events`        | Event queries, streaming (SSE/WebSocket), export, search        |
//! | `health`        | Liveness, readiness and dependency health                       |
//! | `subscriptions` | Subscription creation, unsubscribe links, per-IP limits         |
//! | `webhooks`      | Notification channels, email tracking, circuit breakers, DLQ    |
//! | `admin`         | Indexer control, replay, anonymization, archive, config, export |
//! | `metrics`       | Prometheus scrape, status and operational reports               |
//! | `contracts`     | Contract listing/summary, ABI, metadata, schema registry        |
//! | `chain`         | Networks, ledger hashes, cross-chain correlation                |
//! | `docs`          | OpenAPI JSON and Swagger UI                                     |
//! | `common`        | Helpers shared across domains                                   |
//!
//! Every public handler is re-exported here, so `crate::handlers::<name>`
//! paths keep working. Integration handlers live in `crate::integration_handlers`.
//!
//! The imports below are shared with the submodules via `use super::*;`.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use axum::body::Body;
use axum::http::{header, HeaderMap};
use axum::response::sse::{Event, Sse};
use axum::response::Response;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, Utc};
use futures::stream::{self, Stream, StreamExt};
use reqwest;
use secrecy::ExposeSecret;
use regex::Regex;
use serde_json::{json, Value};
use sqlx::{QueryBuilder, Row};
use std::convert::Infallible;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::sync::Mutex;
use tracing::{info_span, instrument};
use uuid::Uuid;

use crate::{
    error::AppError,
    middleware::TenantId,
    models::{
        self, BatchTxRequest, ContractSummary, ExportParams, PaginationParams, ReplayRequest,
        StreamParams, ContractDetailSummary, ContractSearchParams, ContractSearchResult,
        EventTypeBreakdown, LedgerRange,
    },
    routes::AppState,
    notification_formatter,
    pagerduty,
};
use std::sync::atomic::Ordering;

use crate::anonymization::AnonymizationRuleRequest;

mod admin;
mod chain;
mod common;
mod contracts;
mod docs;
mod events;
mod health;
mod metrics;
mod subscriptions;
mod webhooks;

pub use admin::*;
pub use chain::*;
pub use common::*;
pub use contracts::*;
pub use docs::*;
pub use events::*;
pub use health::*;
pub use metrics::*;
pub use subscriptions::*;
pub use webhooks::*;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod temporal_tests;
#[cfg(test)]
mod ops_tests;
