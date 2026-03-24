use uuid::Uuid;

/// Authenticated user context extracted from a validated JWT.
///
/// Carried through the request lifecycle via Axum extensions.
/// Does NOT depend on any web framework — it is a plain data structure.
#[derive(Debug, Clone)]
pub struct AuthContext {
    pub user_id: Uuid,
    pub email: String,
    pub role: String,
    pub token_id: Uuid,
}

impl AuthContext {
    pub fn is_admin(&self) -> bool {
        self.role == "admin"
    }
}
