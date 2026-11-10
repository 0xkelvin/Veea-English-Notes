use axum::Json;
use axum::response::IntoResponse;

/// GET /api/openapi.json — returns the OpenAPI 3.0 specification.
pub async fn openapi_spec() -> impl IntoResponse {
    let mut spec = serde_json::json!({
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
                "ChangeUserRoleRequest":{ "type": "object", "required": ["role"], "properties": { "role": { "type": "string", "enum": ["user", "admin", "moderator"] } } },
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
    });
    // Kept separate: one json! literal for the whole spec exceeds the macro
    // recursion limit.
    merge(&mut spec["paths"], phone_account_paths());
    merge(&mut spec["components"]["schemas"], phone_account_schemas());
    Json(spec)
}

fn merge(target: &mut serde_json::Value, extra: serde_json::Value) {
    if let (Some(target), serde_json::Value::Object(extra)) = (target.as_object_mut(), extra) {
        target.extend(extra);
    }
}

/// Phone OTP sign-in, verified phone change and recoverable deletion.
fn phone_account_paths() -> serde_json::Value {
    serde_json::json!({
    "/auth/otp/request": {
                "post": {
                    "tags": ["auth"],
                    "summary": "Send a sign-in code to a Vietnamese mobile number",
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PhoneRequest" } } } },
                    "responses": { "200": { "description": "Challenge created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/OtpChallenge" } } } }, "400": { "description": "Invalid phone" }, "429": { "description": "Send rate limit" }, "503": { "description": "OTP delivery unavailable" } }
                }
            },
            "/auth/otp/verify": {
                "post": {
                    "tags": ["auth"],
                    "summary": "Verify a sign-in code; creates the account on first use",
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/VerifyCodeRequest" } } } },
                    "responses": { "200": { "description": "Session", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PhoneSession" } } } }, "400": { "description": "Code incorrect, expired, used or out of attempts" }, "409": { "description": "Legacy account needs a support migration" } }
                }
            },
            "/users/me/delete-otp": {
                "post": {
                    "tags": ["account"],
                    "summary": "Send an account-deletion code to the account's phone",
                    "security": [{ "bearerAuth": [] }],
                    "responses": { "200": { "description": "Challenge created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/OtpChallenge" } } } }, "429": { "description": "Send rate limit" }, "503": { "description": "OTP delivery unavailable" } }
                },
                "delete": {
                    "tags": ["account"],
                    "summary": "Delete the account with a fresh deletion code",
                    "description": "Deletes the user, cloud words, refresh tokens and OTP rows (ON DELETE CASCADE) and, in the same transaction, writes a deletion receipt keyed by the user UUID and a hash of the challenge id. Feedback reports are not deleted.",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/VerifyCodeRequest" } } } },
                    "responses": { "204": { "description": "Account deleted" }, "400": { "description": "Code incorrect or expired; account kept" }, "401": { "description": "Session invalid (also returned after the account is gone; use /auth/deletion-receipt)" } }
                }
            },
            "/auth/deletion-receipt": {
                "post": {
                    "tags": ["account"],
                    "summary": "Check whether a specific deletion challenge deleted an account",
                    "description": "For clients whose deletion response was lost. `deleted: true` only when this challenge deleted this account within the last 30 days. `false` means not proven; the client must keep local data.",
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/DeletionReceiptRequest" } } } },
                    "responses": { "200": { "description": "`{deleted: boolean}`" } }
                }
            },
            "/users/me/phone-change/current-code": {
                "post": {
                    "tags": ["account"],
                    "summary": "Step 1: send a code to the account's current phone",
                    "security": [{ "bearerAuth": [] }],
                    "responses": { "200": { "description": "Challenge created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/OtpChallenge" } } } }, "400": { "description": "Not a phone-code account" }, "429": { "description": "Send rate limit" }, "503": { "description": "OTP delivery unavailable" } }
                }
            },
            "/users/me/phone-change/current-verify": {
                "post": {
                    "tags": ["account"],
                    "summary": "Step 2: verify the current-phone code and receive a proof",
                    "description": "The proof is valid for 15 minutes, belongs to this account and its current number, and can complete one change.",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/VerifyCodeRequest" } } } },
                    "responses": { "200": { "description": "`{proof_id, expires_in}`" }, "400": { "description": "Code incorrect or expired" }, "404": { "description": "Number changed in another session; start again" } }
                }
            },
            "/users/me/phone-change/new-code": {
                "post": {
                    "tags": ["account"],
                    "summary": "Step 3: send a code to the new phone (resend uses the same proof)",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/NewPhoneCodeRequest" } } } },
                    "responses": { "200": { "description": "Challenge created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/OtpChallenge" } } } }, "400": { "description": "Invalid or unchanged phone" }, "404": { "description": "Proof expired, used, foreign or stale; start again" }, "429": { "description": "Send rate limit" }, "503": { "description": "OTP delivery unavailable" } }
                }
            },
            "/users/me/phone-change/confirm": {
                "post": {
                    "tags": ["account"],
                    "summary": "Step 4: verify the new-phone code and move the number",
                    "description": "Atomically re-checks the proof and expected current phone under locks, updates the phone, revokes every refresh token and returns one replacement session. The account UUID is unchanged.",
                    "security": [{ "bearerAuth": [] }],
                    "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/VerifyCodeRequest" } } } },
                    "responses": { "200": { "description": "Replacement session", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/PhoneSession" } } } }, "400": { "description": "Code incorrect or expired" }, "404": { "description": "Proof expired, used or stale; start again" }, "409": { "description": "New number belongs to another account; nothing changed" } }
                }
            }
    })
}

fn phone_account_schemas() -> serde_json::Value {
    serde_json::json!({
    "PhoneRequest": { "type": "object", "required": ["phone"], "properties": { "phone": { "type": "string", "maxLength": 40, "example": "0901234567" } } },
                "VerifyCodeRequest": { "type": "object", "required": ["challenge_id", "code"], "properties": { "challenge_id": { "type": "string", "format": "uuid" }, "code": { "type": "string", "pattern": "^[0-9]{4,10}$" } } },
                "NewPhoneCodeRequest": { "type": "object", "required": ["proof_id", "new_phone"], "properties": { "proof_id": { "type": "string", "format": "uuid" }, "new_phone": { "type": "string", "maxLength": 40 } } },
                "DeletionReceiptRequest": { "type": "object", "required": ["user_id", "challenge_id"], "properties": { "user_id": { "type": "string", "format": "uuid" }, "challenge_id": { "type": "string", "format": "uuid" } } },
                "OtpChallenge": { "type": "object", "required": ["challenge_id", "expires_in", "retry_after"], "properties": { "challenge_id": { "type": "string", "format": "uuid" }, "expires_in": { "type": "integer", "example": 600 }, "retry_after": { "type": "integer", "example": 60 } } },
                "PhoneSession": { "type": "object", "required": ["user_id", "identifier", "auth_method", "tokens"], "properties": { "user_id": { "type": "string", "format": "uuid" }, "identifier": { "type": "string", "example": "+84901234567" }, "auth_method": { "type": "string", "enum": ["phone_otp"] }, "revoked_sessions": { "type": "integer", "description": "Phone change only" }, "tokens": { "type": "object", "properties": { "access_token": { "type": "string" }, "refresh_token": { "type": "string" }, "expires_in": { "type": "integer" }, "token_type": { "type": "string" } } } } }
    })
}
