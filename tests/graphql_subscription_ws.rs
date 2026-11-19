//! Issue #1350: GraphQL subscriptions over WebSocket.
//!
//! Spins up `/graphql/ws` on an ephemeral port, subscribes with a
//! `contractId` filter via `tokio-tungstenite`, publishes events on the
//! broadcast channel and asserts only the matching event arrives within 2 s.
//! Also checks that disconnecting drops the broadcast receiver.
#![cfg(feature = "graphql")]

use axum::{extract::ws::WebSocketUpgrade, routing::get, Router};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use soroban_pulse::graphql_subscriptions::{serve_socket, GraphQLSubscriptionConfig};
use soroban_pulse::models::SorobanEvent;
use std::time::Duration;
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};

fn event(contract_id: &str, ledger: u64) -> SorobanEvent {
    serde_json::from_value(json!({
        "contractId": contract_id,
        "type": "contract",
        "txHash": format!("tx{ledger}"),
        "ledger": ledger,
        "ledgerClosedAt": "2026-01-01T00:00:00Z",
        "value": {},
        "topic": []
    }))
    .expect("valid SorobanEvent fixture")
}

async fn start_server(tx: broadcast::Sender<SorobanEvent>) -> String {
    let app = Router::new().route(
        "/graphql/ws",
        get(move |ws: WebSocketUpgrade| {
            let tx = tx.clone();
            async move {
                ws.protocols(["graphql-transport-ws"]).on_upgrade(move |s| {
                    serve_socket(
                        s,
                        tx,
                        async_graphql::http::WebSocketProtocols::GraphQLWS,
                        GraphQLSubscriptionConfig::default(),
                    )
                })
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("ws://{addr}/graphql/ws")
}

async fn next_json<S>(ws: &mut S) -> Value
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    loop {
        match ws.next().await.expect("socket open").expect("ws ok") {
            Message::Text(t) => return serde_json::from_str(&t).unwrap(),
            _ => continue,
        }
    }
}

#[tokio::test]
async fn subscription_receives_filtered_events_and_cleans_up() {
    let (tx, _keep) = broadcast::channel::<SorobanEvent>(16);
    let url = start_server(tx.clone()).await;

    let mut req = url.into_client_request().unwrap();
    req.headers_mut()
        .insert("Sec-WebSocket-Protocol", "graphql-transport-ws".parse().unwrap());
    let (mut ws, _) = tokio_tungstenite::connect_async(req).await.unwrap();

    ws.send(Message::Text(json!({"type": "connection_init"}).to_string()))
        .await
        .unwrap();
    assert_eq!(next_json(&mut ws).await["type"], "connection_ack");

    ws.send(Message::Text(
        json!({
            "id": "1",
            "type": "subscribe",
            "payload": {"query": "subscription { events(contractId: \"CABC\") { contractId ledger } }"}
        })
        .to_string(),
    ))
    .await
    .unwrap();

    // Wait for the per-connection receiver to be registered.
    for _ in 0..50 {
        if tx.receiver_count() >= 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(tx.receiver_count(), 2, "subscription receiver registered");

    tx.send(event("COTHER", 1)).unwrap();
    tx.send(event("CABC", 2)).unwrap();

    let msg = tokio::time::timeout(Duration::from_secs(2), next_json(&mut ws))
        .await
        .expect("event delivered within 2s");
    assert_eq!(msg["type"], "next");
    assert_eq!(msg["payload"]["data"]["events"]["contractId"], "CABC");
    assert_eq!(msg["payload"]["data"]["events"]["ledger"], 2);

    ws.close(None).await.unwrap();
    drop(ws);

    for _ in 0..100 {
        if tx.receiver_count() == 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(tx.receiver_count(), 1, "receiver dropped after disconnect");
}
