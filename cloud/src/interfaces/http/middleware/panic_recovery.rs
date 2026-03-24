use tower_http::catch_panic::CatchPanicLayer;

/// Build a layer that catches panics and returns 500 instead of dropping the connection.
pub fn catch_panic_layer() -> CatchPanicLayer<tower_http::catch_panic::DefaultResponseForPanic> {
    CatchPanicLayer::new()
}
