use tower_http::compression::CompressionLayer;

/// Build gzip compression layer for responses.
pub fn compression_layer() -> CompressionLayer {
    CompressionLayer::new().gzip(true)
}
