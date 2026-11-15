-- +goose Up
ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name text CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 64);
ALTER TABLE users ADD COLUMN IF NOT EXISTS preferred_language text NOT NULL DEFAULT 'en' CHECK (preferred_language IN ('en', 'vi'));
ALTER TABLE users ADD COLUMN IF NOT EXISTS time_zone text NOT NULL DEFAULT 'UTC';
ALTER TABLE users ADD COLUMN IF NOT EXISTS daily_goal integer NOT NULL DEFAULT 20 CHECK (daily_goal BETWEEN 1 AND 1000);
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_revision bigint NOT NULL DEFAULT 0 CHECK (profile_revision >= 0);
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_revision bigint NOT NULL DEFAULT 0 CHECK (email_revision >= 0);

CREATE TABLE IF NOT EXISTS email_changes (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id uuid NOT NULL,
    source_email_normalized text NOT NULL,
    source_revision bigint NOT NULL,
    new_email text NOT NULL,
    new_email_normalized text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    closed_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS email_changes_one_pending ON email_changes(user_id) WHERE closed_at IS NULL;

ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS email_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS change_id uuid REFERENCES email_changes(id) ON DELETE CASCADE;
ALTER TABLE otp_challenges DROP CONSTRAINT IF EXISTS otp_none_inert,
    ADD CONSTRAINT otp_none_inert CHECK (delivery = 'code' OR
        (consumed_at IS NULL AND pending_password_hash IS NULL AND
         ((change_id IS NULL AND user_id IS NULL AND session_id IS NULL) OR
          (change_id IS NOT NULL AND user_id IS NOT NULL AND session_id IS NOT NULL))));
ALTER TABLE otp_challenges DROP CONSTRAINT IF EXISTS otp_email_change_binding,
    ADD CONSTRAINT otp_email_change_binding CHECK
      ((purpose IN ('email_change_current','email_change_new')) = (change_id IS NOT NULL)
       AND (change_id IS NULL OR (user_id IS NOT NULL AND session_id IS NOT NULL)));
ALTER TABLE otp_challenges DROP CONSTRAINT IF EXISTS otp_challenges_purpose_check,
    ADD CONSTRAINT otp_challenges_purpose_check CHECK (purpose IN ('signup','login','password_reset','set_password','email_change_current','email_change_new'));
DROP INDEX IF EXISTS otp_challenges_one_open;
CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_one_open ON otp_challenges(purpose,email_normalized)
    WHERE consumed_at IS NULL AND superseded_at IS NULL AND change_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_change_open ON otp_challenges(change_id,purpose)
    WHERE consumed_at IS NULL AND superseded_at IS NULL AND change_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS otp_challenges_change ON otp_challenges(change_id);

ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_revoked_reason_check,
    ADD CONSTRAINT sessions_revoked_reason_check CHECK (revoked_reason IN ('logout','password_set','password_change','password_reset','refresh_reuse','session_limit','account_inactive','user_revoked','logout_all','email_change'));
ALTER TABLE email_outbox DROP CONSTRAINT IF EXISTS email_outbox_template_check,
    ADD CONSTRAINT email_outbox_template_check CHECK (template IN ('signup_code','login_code','reset_code','set_password_code','password_added','password_changed','password_reset_done','email_change_current_code','email_change_new_code','email_changed_old','email_changed_new'));

CREATE INDEX IF NOT EXISTS email_changes_expires ON email_changes(expires_at);
