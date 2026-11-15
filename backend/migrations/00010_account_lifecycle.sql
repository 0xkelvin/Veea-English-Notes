-- +goose Up
ALTER TABLE users ADD COLUMN IF NOT EXISTS lifecycle_revision bigint NOT NULL DEFAULT 0 CHECK (lifecycle_revision >= 0);
ALTER TABLE users ADD COLUMN IF NOT EXISTS state_changed_at timestamptz;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS lifecycle_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS operation_id uuid;
ALTER TABLE otp_challenges DROP CONSTRAINT IF EXISTS otp_challenges_purpose_check,
 ADD CONSTRAINT otp_challenges_purpose_check CHECK (purpose IN ('signup','login','password_reset','set_password','email_change_current','email_change_new','account_export','account_delete','account_reactivate'));
CREATE INDEX IF NOT EXISTS otp_challenges_user ON otp_challenges(user_id,id);
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_revoked_reason_check,
 ADD CONSTRAINT sessions_revoked_reason_check CHECK (revoked_reason IN ('logout','password_set','password_change','password_reset','refresh_reuse','session_limit','account_inactive','user_revoked','logout_all','email_change','deactivated','account_delete'));
ALTER TABLE email_outbox DROP CONSTRAINT IF EXISTS email_outbox_template_check,
 ADD CONSTRAINT email_outbox_template_check CHECK (template IN ('signup_code','login_code','reset_code','set_password_code','password_added','password_changed','password_reset_done','email_change_current_code','email_change_new_code','email_changed_old','email_changed_new','account_export_code','account_delete_code','account_reactivate_code'));

-- Deliberately no user FK: a deletion receipt must survive account erasure. No email or code.
CREATE TABLE IF NOT EXISTS account_operations (
 id uuid PRIMARY KEY,
 token_hash bytea UNIQUE,
 action text NOT NULL CHECK(action IN ('export','delete','reactivate')),
 user_id uuid,
 challenge_id uuid NOT NULL,
 email_revision bigint NOT NULL,
 lifecycle_revision bigint NOT NULL,
 state text NOT NULL DEFAULT 'awaiting_proof' CHECK(state IN ('awaiting_proof','pending','ready','completed','canceled','expired')),
 created_at timestamptz NOT NULL DEFAULT now(),
 proof_expires_at timestamptz NOT NULL,
 accepted_at timestamptz,
 completed_at timestamptz,
 expires_at timestamptz NOT NULL,
 download_expires_at timestamptz,
 artifact_id uuid NOT NULL,
 artifact_ciphertext bytea,
 artifact_key_id smallint,
 purge_step integer NOT NULL DEFAULT 0 CHECK(purge_step BETWEEN 0 AND 2),
 email_digests bytea[] NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS account_operations_jobs ON account_operations(created_at,id) WHERE state='pending';
CREATE INDEX IF NOT EXISTS account_operations_owner ON account_operations(user_id);
CREATE INDEX IF NOT EXISTS account_operations_expires ON account_operations(expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS account_operations_one_delete ON account_operations(user_id) WHERE action='delete' AND accepted_at IS NOT NULL;
CREATE TABLE IF NOT EXISTS deletion_ledger (
 operation_id uuid PRIMARY KEY,
 user_id uuid NOT NULL UNIQUE,
 accepted_at timestamptz NOT NULL,
 completed_at timestamptz,
 retain_until timestamptz
);
CREATE INDEX IF NOT EXISTS deletion_ledger_retain ON deletion_ledger(retain_until);
CREATE TABLE IF NOT EXISTS erased_addresses (
 email_hmac bytea PRIMARY KEY,
 cutoff timestamptz NOT NULL,
 expires_at timestamptz
);
CREATE INDEX IF NOT EXISTS erased_addresses_expires ON erased_addresses(expires_at);
ALTER TABLE otp_challenges DROP CONSTRAINT IF EXISTS otp_operation_binding,
 ADD CONSTRAINT otp_operation_binding CHECK ((purpose IN ('account_export','account_delete','account_reactivate')) = (operation_id IS NOT NULL));
CREATE INDEX IF NOT EXISTS audit_events_retention ON audit_events(occurred_at,id);
