//! The provider transport, end to end, without a key.
//!
//! Unit tests cover the stream state machines against recorded bytes. What
//! they cannot cover is the wiring: that the request is actually built and
//! sent, that the response is decoded as it arrives rather than at the end,
//! and that a non-200 turns into a message a person can act on.
//!
//! So this serves a canned SSE response from a local socket and drives the
//! real `HttpModel` against it. No network, no key, no vendor.

use std::sync::Arc;

use parking_lot::Mutex;
use reve::model::{Model, Request, StopReason, ToolSchema};
use reve::provider::HttpModel;
use reve::provider::config::{Api, Compat, ModelSpec, Resolved};
use reve::records::{Entry, MAIN_LANE};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Serve one request, then stop. Returns the address and the request body.
async fn serve(status: &'static str, body: &'static str) -> (String, Arc<Mutex<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let seen = Arc::new(Mutex::new(String::new()));
    let captured = seen.clone();

    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut buffer = vec![0u8; 64 * 1024];
        let read = socket.read(&mut buffer).await.unwrap_or(0);
        *captured.lock() = String::from_utf8_lossy(&buffer[..read]).into_owned();

        let response = format!(
            "HTTP/1.1 {status}\r\ncontent-type: text/event-stream\r\n\
             content-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = socket.write_all(response.as_bytes()).await;
        let _ = socket.flush().await;
    });

    (format!("http://{addr}"), seen)
}

fn model(api: Api, base_url: String) -> HttpModel {
    HttpModel::new(Resolved {
        provider: "local".into(),
        api,
        base_url,
        api_key: Some("test-key".into()),
        model: ModelSpec {
            id: "test-model".into(),
            reasoning: false,
            context_window: 1000,
            max_tokens: 64,
        },
        compat: Compat {
            max_tokens_field: "max_tokens".into(),
            ..Default::default()
        },
    })
}

const OPENAI_STREAM: &str = "\
event: response.output_text.delta\ndata: {\"item_id\":\"m\",\"delta\":\"Hello \"}\n\n\
event: response.output_text.delta\ndata: {\"item_id\":\"m\",\"delta\":\"from the wire\"}\n\n\
event: response.completed\ndata: {\"response\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}}\n\n";

#[tokio::test]
async fn an_openai_response_is_streamed_and_assembled() {
    let (base, request) = serve("200 OK", OPENAI_STREAM).await;
    let model = model(Api::OpenaiResponses, base);

    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = seen.clone();
    let turn = model
        .respond(
            Request {
                context: &[],
                system: "be terse",
                tools: &[],
            },
            &move |delta: &str| sink.lock().push(delta.to_string()),
        )
        .await
        .expect("the turn succeeds");

    assert_eq!(turn.text, "Hello from the wire");
    assert_eq!(turn.usage.input, 7);
    assert_eq!(turn.stop_reason, StopReason::Stop);
    assert_eq!(
        *seen.lock(),
        vec!["Hello ".to_string(), "from the wire".to_string()],
        "text was delivered as it arrived, not in one lump at the end"
    );

    // And the request we actually put on the wire is the right one.
    let request = request.lock().clone();
    assert!(request.starts_with("POST /responses "), "{request}");
    assert!(
        request.contains("authorization: Bearer test-key"),
        "{request}"
    );
    assert!(request.contains("\"stream\":true"), "{request}");
    assert!(
        request.contains("\"instructions\":\"be terse\""),
        "{request}"
    );
}

const CHAT_STREAM: &str = "\
data: {\"choices\":[{\"delta\":{\"content\":\"chat works\"},\"finish_reason\":null}]}\n\n\
data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":2}}\n\n\
data: [DONE]\n\n";

#[tokio::test]
async fn a_chat_completion_streams_and_replays_tool_history() {
    let (base, request) = serve("200 OK", CHAT_STREAM).await;
    let model = model(Api::OpenaiCompletions, base);
    let context = vec![
        Entry::message(
            MAIN_LANE,
            json!({
                "role": "assistant",
                "content": [{
                    "type": "toolCall",
                    "id": "call_1",
                    "name": "read",
                    "arguments": {"path": "AGENTS.md"},
                }],
            }),
        ),
        Entry::message(
            MAIN_LANE,
            json!({
                "role": "toolResult",
                "toolCallId": "call_1",
                "content": [{"type": "text", "text": "file body"}],
            }),
        ),
    ];
    let tools = vec![ToolSchema {
        name: "read".into(),
        description: "read a file".into(),
        schema: json!({"type": "object"}),
    }];
    let turn = model
        .respond(
            Request {
                context: &context,
                system: "be terse",
                tools: &tools,
            },
            &|_| {},
        )
        .await
        .expect("the turn succeeds");

    assert_eq!(turn.text, "chat works");
    assert_eq!(turn.usage.input, 12);
    assert_eq!(turn.usage.output, 2);
    let request = request.lock().clone();
    assert!(request.starts_with("POST /chat/completions "), "{request}");
    let body: serde_json::Value = serde_json::from_str(
        request
            .split_once("\r\n\r\n")
            .expect("HTTP body separator")
            .1,
    )
    .unwrap();
    assert_eq!(body["messages"][0]["role"], "developer");
    assert_eq!(body["messages"][1]["tool_calls"][0]["id"], "call_1");
    assert_eq!(body["messages"][2]["role"], "tool");
    assert_eq!(body["messages"][2]["tool_call_id"], "call_1");
    assert_eq!(body["tools"][0]["function"]["name"], "read");
}

const ANTHROPIC_STREAM: &str = "\
event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11}}}\n\n\
event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n\
event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n\
event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

#[tokio::test]
async fn an_anthropic_response_uses_its_own_headers_and_path() {
    let (base, request) = serve("200 OK", ANTHROPIC_STREAM).await;
    let model = model(Api::AnthropicMessages, base);

    let turn = model
        .respond(
            Request {
                context: &[],
                system: "",
                tools: &[],
            },
            &|_| {},
        )
        .await
        .expect("the turn succeeds");
    assert_eq!(turn.text, "hi");
    assert_eq!(turn.usage.input, 11);
    assert_eq!(turn.usage.output, 2);

    let request = request.lock().clone();
    assert!(request.starts_with("POST /v1/messages "), "{request}");
    assert!(
        request.contains("x-api-key: test-key"),
        "the other vendor's spelling: {request}"
    );
    assert!(
        request.contains("anthropic-version: 2023-06-01"),
        "{request}"
    );
    assert!(
        !request.contains("authorization:"),
        "and not a bearer token: {request}"
    );
}

#[tokio::test]
async fn a_failing_status_reports_the_provider_model_and_body() {
    let (base, _) = serve("429 Too Many Requests", "{\"error\":\"slow down\"}").await;
    let model = model(Api::OpenaiResponses, base);

    let err = model
        .respond(
            Request {
                context: &[],
                system: "",
                tools: &[],
            },
            &|_| {},
        )
        .await
        .expect_err("a 429 is an error");
    let message = err.to_string();
    // Everything needed to act on it, without opening a log.
    assert!(message.contains("local"), "which provider: {message}");
    assert!(message.contains("test-model"), "which model: {message}");
    assert!(message.contains("429"), "what happened: {message}");
    assert!(message.contains("slow down"), "and what it said: {message}");
}

#[tokio::test]
async fn an_unreachable_endpoint_names_the_url_it_tried() {
    // Port 1 is reserved and nothing listens there.
    let model = model(Api::OpenaiResponses, "http://127.0.0.1:1".into());
    let err = model
        .respond(
            Request {
                context: &[],
                system: "",
                tools: &[],
            },
            &|_| {},
        )
        .await
        .expect_err("nothing is listening");
    let message = err.to_string();
    assert!(message.contains("127.0.0.1:1/responses"), "{message}");
}
