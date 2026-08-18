-- Let an account be identified by a phone number as well as an email.
--
-- Either one may be absent, but not both — an account with neither could
-- never be signed into again.

ALTER TABLE users ADD COLUMN IF NOT EXISTS phone TEXT;

-- Existing rows all have an email, so relaxing this is safe.
ALTER TABLE users ALTER COLUMN email DROP NOT NULL;

-- Phone numbers are stored E.164-normalised, so plain uniqueness is enough.
-- A partial index keeps NULLs out of it, allowing many email-only accounts.
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_phone
    ON users (phone)
    WHERE phone IS NOT NULL;

-- The original email constraint was a plain UNIQUE, which in Postgres already
-- permits multiple NULLs, so it needs no change.

ALTER TABLE users
    ADD CONSTRAINT ck_users_has_identifier
    CHECK (email IS NOT NULL OR phone IS NOT NULL);
