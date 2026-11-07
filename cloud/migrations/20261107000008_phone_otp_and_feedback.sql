ALTER TABLE users ADD COLUMN phone_verified_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN auth_method TEXT NOT NULL DEFAULT 'password';

CREATE TABLE otp_challenges (
    id UUID PRIMARY KEY,
    phone TEXT NOT NULL,
    ip_hash TEXT NOT NULL,
    purpose TEXT NOT NULL CHECK (purpose IN ('signin', 'delete')),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    provider_sid TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ
);
CREATE INDEX otp_phone_created ON otp_challenges(phone, created_at);
CREATE INDEX otp_ip_created ON otp_challenges(ip_hash, created_at);

CREATE TABLE feedback_reports (
    id UUID PRIMARY KEY,
    owner_hash TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('bug', 'feature', 'other')),
    message TEXT NOT NULL CHECK (char_length(message) BETWEEN 5 AND 4000),
    contact TEXT CHECK (char_length(contact) <= 254),
    diagnostics JSONB NOT NULL DEFAULT '{}',
    screenshot BYTEA CHECK (octet_length(screenshot) <= 524288),
    status TEXT NOT NULL DEFAULT 'received' CHECK (status IN ('received','reviewing','planned','completed','closed')),
    team_reply TEXT CHECK (char_length(team_reply) <= 2000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX feedback_owner_created ON feedback_reports(owner_hash, created_at DESC);
