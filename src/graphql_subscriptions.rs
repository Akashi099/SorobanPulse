//! Issue #878 / #1350: GraphQL subscriptions over WebSocket.
//!
//! `GET /graphql/ws` upgrades to a WebSocket speaking either the
//! `graphql-transport-ws` or legacy `graphql-ws` sub-protocol and executes
//! subscriptions against [`crate::graphql::create_schema`]. Each connection
//! gets its own `broadcast::Receiver` from `AppState::event_tx`; when the
//! socket closes, the connection future (and with it the receiver) is dropped,
//! which removes the subscription from the broadcast channel.

use async_graphql::http::{WebSocket as GqlWebSocket, WebSocketProtocols, WsMessage};
use async_graphql::Data;
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::HeaderMap,
    response::Response,
};
use futures_util::{SinkExt, StreamExt};
use std::str::FromStr;
use std::time::Duration;
use tokio::sync::broadcast;
use tracing::{debug, warn};

use crate::{models::SorobanEvent, routes::AppState};

/// Default WebSocket connection timeout (5 minutes)
const DEFAULT_CONNECTION_TIMEOUT_SECS: u64 = 300;

/// Default keep-alive ping interval (30 seconds)
const DEFAULT_KEEPALIVE_INTERVAL_SECS: u64 = 30;

/// Configuration for GraphQL WebSocket subscriptions
#[derive(Debug, Clone)]
pub struct GraphQLSubscriptionConfig {
    /// Connection timeout in seconds
    pub connection_timeout_secs: u64,
    /// Keep-alive ping interval in seconds
    pub keepalive_interval_secs: u64,
    /// Maximum message size in bytes
    pub max_message_size: usize,
    /// Broadcast channel capacity
    pub channel_capacity: usize,
}

impl Default for GraphQLSubscriptionConfig {
    fn default() -> Self {
        Self {
            connection_timeout_secs: DEFAULT_CONNECTION_TIMEOUT_SECS,
            keepalive_interval_secs: DEFAULT_KEEPALIVE_INTERVAL_SECS,
            max_message_size: 65536,
            channel_capacity: 100,
        }
    }
}

/// Pick the GraphQL WebSocket sub-protocol requested by the client
/// (defaults to `graphql-transport-ws`).
pub fn negotiate_protocol(headers: &HeaderMap) -> WebSocketProtocols {
    headers
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| {
            v.split(',')
                .find_map(|p| WebSocketProtocols::from_str(p.trim()).ok())
        })
        .unwrap_or(WebSocketProtocols::GraphQLWS)
}

/// `GET /graphql/ws` — upgrade to a GraphQL subscription WebSocket.
pub async fn handle_graphql_ws(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let protocol = negotiate_protocol(&headers);
    let config = GraphQLSubscriptionConfig::default();
    ws.protocols(["graphql-transport-ws", "graphql-ws"])
        .max_message_size(config.max_message_size)
        .on_upgrade(move |socket| serve_socket(socket, state.event_tx.clone(), protocol, config))
}

/// Drive one GraphQL subscription WebSocket until the client disconnects or
/// the idle timeout elapses. Public so it can be mounted without a full
/// `AppState` (used by the integration tests).
pub async fn serve_socket(
    socket: WebSocket,
    event_tx: broadcast::Sender<SorobanEvent>,
    protocol: WebSocketProtocols,
    config: GraphQLSubscriptionConfig,
) {
    let schema = crate::graphql::create_schema();

    let (mut sink, stream) = socket.split();
    let incoming = stream
        .take_while(|m| std::future::ready(m.is_ok()))
        .filter_map(|m| async move {
            match m {
                Ok(Message::Text(t)) => Some(t.to_string()),
                Ok(Message::Binary(b)) => String::from_utf8(b.to_vec()).ok(),
                _ => None,
            }
        });

    let mut gql = GqlWebSocket::new(schema, incoming, protocol)
        .on_connection_init(move |_payload| {
            // A fresh receiver per connection; dropped when the socket closes.
            let rx = event_tx.subscribe();
            async move {
                let mut data = Data::default();
                data.insert(rx);
                Ok(data)
            }
        })
        .keepalive_timeout(Some(Duration::from_secs(config.keepalive_interval_secs)));

    let idle = Duration::from_secs(config.connection_timeout_secs);
    loop {
        match tokio::time::timeout(idle, gql.next()).await {
            Ok(Some(WsMessage::Text(text))) => {
                if sink.send(Message::Text(text.into())).await.is_err() {
                    debug!("GraphQL WS client disconnected");
                    break;
                }
            }
            Ok(Some(WsMessage::Close(code, reason))) => {
                let _ = sink
                    .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                        code,
                        reason: reason.into(),
                    })))
                    .await;
                break;
            }
            Ok(None) => break,
            Err(_) => {
                warn!("GraphQL WS connection idle timeout reached");
                let _ = sink.send(Message::Close(None)).await;
                break;
            }
        }
    }
    // `gql` (and the broadcast receiver it owns) is dropped here.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_has_reasonable_values() {
        let config = GraphQLSubscriptionConfig::default();
        assert_eq!(config.connection_timeout_secs, 300);
        assert_eq!(config.keepalive_interval_secs, 30);
        assert!(config.max_message_size > 0);
        assert!(config.channel_capacity > 0);
    }

    #[test]
    fn connection_timeout_is_greater_than_keepalive() {
        let config = GraphQLSubscriptionConfig::default();
        assert!(config.connection_timeout_secs > config.keepalive_interval_secs);
    }

    #[test]
    fn negotiates_legacy_protocol() {
        let mut h = HeaderMap::new();
        h.insert("sec-websocket-protocol", "graphql-ws".parse().unwrap());
        assert_eq!(negotiate_protocol(&h), WebSocketProtocols::SubscriptionsTransportWS);
    }

    #[test]
    fn defaults_to_transport_ws() {
        assert_eq!(negotiate_protocol(&HeaderMap::new()), WebSocketProtocols::GraphQLWS);
    }
}
