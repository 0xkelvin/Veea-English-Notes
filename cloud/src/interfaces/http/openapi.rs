use axum::response::IntoResponse;
use axum::Json;

/// GET /api/openapi.json — returns the OpenAPI 3.0 specification.
pub async fn openapi_spec() -> impl IntoResponse {
    Json(serde_json::json!({
        "openapi": "3.0.3",
        "info": {
            "title": "English Notes Backend API",
            "version": "1.0.0",
            "description": "Production-grade identity & notes microservice."
        },
        "servers": [{ "url": "/api/v1" }],
        "paths": {
            "/auth/register": {
                "post": {
                    "tags": ["auth"],
                    "summary": "Register a new user",
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/RegisterUserRequest" } } } },
                    "responses": { "201": { "description": "User created" }, "400": { "description": "Validation error" }, "409": { "description": "Email conflict" } }
                }
            },
            "/auth/login": {
                "post": {
                    "tags": ["auth"],
                    "summary": "Authenticate and receive tokens",
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/LoginRequest" } } } },
                    "responses": { "200": { "description": "OK" }, "401": { "description": "Invalid credentials" } }
                }
            },
            "/auth/refresh": {
                "post": {
                    "tags": ["auth"],
                    "summary": "Refresh access token",
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/RefreshTokenRequest" } } } },
                    "responses": { "200": { "description": "OK" }, "401": { "description": "Invalid or expired token" } }
                }
            },
            "/auth/logout": {
                "post": {
                    "tags": ["auth"],
                    "summary": "Revoke refresh token (logout)",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/LogoutRequest" } } } },
                    "responses": { "204": { "description": "Logged out" } }
                }
            },
            "/users/me": {
                "get": {
                    "tags": ["users"],
                    "summary": "Get current user profile",
                    "security": [{ "bearerAuth": [] }],
                    "responses": { "200": { "description": "OK" }, "401": { "description": "Unauthorized" } }
                }
            },
            "/admin/users": {
                "get": {
                    "tags": ["admin"],
                    "summary": "List users (admin)",
                    "security": [{ "bearerAuth": [] }],
                    "parameters": [
                        { "name": "page", "in": "query", "schema": { "type": "integer", "default": 1 } },
                        { "name": "per_page", "in": "query", "schema": { "type": "integer", "default": 20 } }
                    ],
                    "responses": { "200": { "description": "OK" }, "403": { "description": "Forbidden" } }
                }
            },
            "/admin/users/{id}/role": {
                "put": {
                    "tags": ["admin"],
                    "summary": "Change user role (admin)",
                    "security": [{ "bearerAuth": [] }],
                    "parameters": [{ "name": "id", "in": "path", "required": true, "schema": { "type": "string", "format": "uuid" } }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ChangeUserRoleRequest" } } } },
                    "responses": { "200": { "description": "OK" }, "403": { "description": "Forbidden" } }
                }
            }
        },
        "components": {
            "securitySchemes": {
                "bearerAuth": { "type": "http", "scheme": "bearer", "bearerFormat": "JWT" }
            },
            "schemas": {
                "RegisterUserRequest": { "type": "object", "required": ["email", "password"], "properties": { "email": { "type": "string", "format": "email" }, "password": { "type": "string", "minLength": 8 } } },
                "LoginRequest": { "type": "object", "required": ["email", "password"], "properties": { "email": { "type": "string" }, "password": { "type": "string" } } },
                "RefreshTokenRequest": { "type": "object", "required": ["refresh_token"], "properties": { "refresh_token": { "type": "string" } } },
                "LogoutRequest": { "type": "object", "required": ["refresh_token"], "properties": { "refresh_token": { "type": "string" } } },
                "ChangeUserRoleRequest": { "type": "object", "required": ["role"], "properties": { "role": { "type": "string", "enum": ["user", "admin", "moderator"] } } }
            }
        }
    }))
}
