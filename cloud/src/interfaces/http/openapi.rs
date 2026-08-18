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
                },
                "delete": {
                    "tags": ["account"],
                    "summary": "Permanently delete the caller's account",
                    "description": "Irreversible. Vocabulary and refresh tokens are removed with the account by ON DELETE CASCADE. The current password is required again because an access token alone is a weaker signal for an action with no way back.",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/DeleteAccountRequest" } } } },
                    "responses": { "204": { "description": "Account deleted" }, "401": { "description": "Wrong password" } }
                }
            },
            "/users/me/password": {
                "put": {
                    "tags": ["account"],
                    "summary": "Change the caller's password",
                    "description": "Revokes every refresh token, including the caller's own, so the client must sign in again with the new password.",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ChangePasswordRequest" } } } },
                    "responses": { "204": { "description": "Password changed; all sessions revoked" }, "400": { "description": "New password rejected" }, "401": { "description": "Wrong current password" } }
                }
            },
            "/users/me/identifier": {
                "put": {
                    "tags": ["account"],
                    "summary": "Set the caller's email address or phone number",
                    "description": "Replaces only the matching kind: setting a phone on an email account keeps the email, so the account stays reachable both ways. An account can never be left with neither.",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ChangeIdentifierRequest" } } } },
                    "responses": { "200": { "description": "Updated profile" }, "401": { "description": "Wrong password" }, "409": { "description": "Already registered to another account" } }
                }
            },
            "/users/me/export": {
                "get": {
                    "tags": ["account"],
                    "summary": "Export every word the account holds",
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
            },
            "/vocabulary/sync": {
                "post": {
                    "tags": ["vocabulary"],
                    "summary": "Push local changes and pull remote ones in a single round trip",
                    "description": "Conflicts resolve last-write-wins on `updatedAt`. Ids absent from `accepted` belong to another user and must not be retried. Advance the local cursor to `serverTime` only after every returned change has been applied; repeat while `hasMore` is true.",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SyncRequest" } } } },
                    "responses": { "200": { "description": "OK" }, "400": { "description": "Validation error" }, "401": { "description": "Unauthorized" } }
                }
            },
            "/vocabulary/words": {
                "get": {
                    "tags": ["vocabulary"],
                    "summary": "List the caller's vocabulary, newest day first",
                    "security": [{ "bearerAuth": [] }],
                    "parameters": [
                        { "name": "page", "in": "query", "schema": { "type": "integer", "default": 1 } },
                        { "name": "per_page", "in": "query", "schema": { "type": "integer", "default": 20 } }
                    ],
                    "responses": { "200": { "description": "OK" }, "401": { "description": "Unauthorized" } }
                }
            }
        },
        "components": {
            "securitySchemes": {
                "bearerAuth": { "type": "http", "scheme": "bearer", "bearerFormat": "JWT" }
            },
            "schemas": {
                "RegisterUserRequest": { "type": "object", "required": ["identifier", "password"], "properties": { "identifier": { "$ref": "#/components/schemas/Identifier" }, "password": { "type": "string", "minLength": 8, "maxLength": 128 } } },
                "LoginRequest": { "type": "object", "required": ["identifier", "password"], "properties": { "identifier": { "$ref": "#/components/schemas/Identifier" }, "password": { "type": "string" } } },
                "Identifier": { "type": "string", "maxLength": 254, "description": "An email address or a phone number; the server decides which from its shape. Phone numbers require an international prefix and are stored E.164-normalised, so +84 90 123 4567 and +84-901-234-567 are the same account. A bare national number such as 0901234567 is rejected, since resolving it would mean guessing a country.", "example": "+84901234567" },
                "DeleteAccountRequest": { "type": "object", "required": ["password"], "properties": { "password": { "type": "string" } } },
                "ChangePasswordRequest": { "type": "object", "required": ["current_password", "new_password"], "properties": { "current_password": { "type": "string" }, "new_password": { "type": "string", "minLength": 8, "maxLength": 128 } } },
                "ChangeIdentifierRequest": { "type": "object", "required": ["identifier", "password"], "properties": { "identifier": { "$ref": "#/components/schemas/Identifier" }, "password": { "type": "string" } } },
                "RefreshTokenRequest": { "type": "object", "required": ["refresh_token"], "properties": { "refresh_token": { "type": "string" } } },
                "LogoutRequest": { "type": "object", "required": ["refresh_token"], "properties": { "refresh_token": { "type": "string" } } },
                "ChangeUserRoleRequest": { "type": "object", "required": ["role"], "properties": { "role": { "type": "string", "enum": ["user", "admin", "moderator"] } } },
                "Word": {
                    "type": "object",
                    "required": ["id", "word", "meaning", "date", "createdAt", "updatedAt"],
                    "properties": {
                        "id": { "type": "string", "format": "uuid", "description": "Generated by the client so an offline capture keeps one identity across devices." },
                        "word": { "type": "string", "maxLength": 512 },
                        "meaning": { "type": "string", "maxLength": 512 },
                        "pronunciation": { "type": "string", "nullable": true, "example": "/rɪˈzɪliənt/" },
                        "partOfSpeech": { "type": "string", "nullable": true, "enum": ["n", "v", "adj", "adv", "phr", "idm", "etc"] },
                        "source": { "type": "string", "nullable": true, "description": "Where the word was encountered." },
                        "examples": { "type": "array", "items": { "type": "string" }, "maxItems": 25 },
                        "tags": { "type": "array", "items": { "type": "string" }, "maxItems": 25 },
                        "date": { "type": "string", "format": "date", "example": "2026-08-18" },
                        "createdAt": { "type": "string", "format": "date-time" },
                        "updatedAt": { "type": "string", "format": "date-time", "description": "Client clock; drives last-write-wins." },
                        "deleted": { "type": "boolean", "default": false, "description": "Tombstone, so the deletion reaches other devices." }
                    }
                },
                "SyncRequest": {
                    "type": "object",
                    "properties": {
                        "changes": { "type": "array", "items": { "$ref": "#/components/schemas/Word" }, "maxItems": 500 },
                        "since": { "type": "string", "format": "date-time", "nullable": true, "description": "Highest serverTime already applied. Omit for a full download." }
                    }
                },
                "SyncResponse": {
                    "type": "object",
                    "required": ["accepted", "changes", "serverTime", "hasMore"],
                    "properties": {
                        "accepted": { "type": "array", "items": { "type": "string", "format": "uuid" } },
                        "changes": { "type": "array", "items": { "$ref": "#/components/schemas/Word" } },
                        "serverTime": { "type": "string", "format": "date-time" },
                        "hasMore": { "type": "boolean" }
                    }
                }
            }
        }
    }))
}
