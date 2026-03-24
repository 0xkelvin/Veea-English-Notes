use super::error::AppError;

/// Alias for `Result<T, AppError>` used throughout the application.
pub type AppResult<T> = std::result::Result<T, AppError>;
