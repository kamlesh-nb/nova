// Rust peer: axum + tokio (the idiomatic async web stack). GET / returns a constant JSON body.
use axum::{http::header, response::IntoResponse, routing::get, Router};

async fn handler() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "application/json")],
        r#"{"message":"Hello, World!"}"#,
    )
}

#[tokio::main]
async fn main() {
    let app = Router::new().route("/", get(handler));
    let port = std::env::var("PORT").unwrap_or_else(|_| "8082".to_string());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}"))
        .await
        .unwrap();
    axum::serve(listener, app).await.unwrap();
}
