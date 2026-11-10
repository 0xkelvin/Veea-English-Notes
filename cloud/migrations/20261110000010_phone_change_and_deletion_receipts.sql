-- Verified phone-number change and recoverable account-deletion outcomes.

-- Two new account-bound OTP purposes: proving the current phone, then the new one.
ALTER TABLE otp_challenges DROP CONSTRAINT IF EXISTS otp_challenges_purpose_check;
ALTER TABLE otp_challenges
    ADD CONSTRAINT otp_challenges_purpose_check
    CHECK (purpose IN ('signin', 'delete', 'change_current', 'change_new'));

-- A change_new challenge points at the consumed change_current challenge that
-- authorised it, and records the account phone that proof was made for, so a
-- stale proof cannot complete a change after the number moved elsewhere.
ALTER TABLE otp_challenges
    ADD COLUMN IF NOT EXISTS proof_challenge_id UUID REFERENCES otp_challenges(id) ON DELETE CASCADE;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS expected_phone TEXT;
-- Set once a change_current proof completes a change: one proof, one change.
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS proof_spent_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_otp_challenges_proof ON otp_challenges(proof_challenge_id)
    WHERE proof_challenge_id IS NOT NULL;

-- Every purpose except sign-in is bound to an account; change_new is also
-- bound to its proof.
ALTER TABLE otp_challenges
    ADD CONSTRAINT ck_otp_account_purposes_bound
    CHECK (purpose = 'signin' OR user_id IS NOT NULL);
ALTER TABLE otp_challenges
    ADD CONSTRAINT ck_otp_change_new_has_proof
    CHECK (purpose <> 'change_new' OR (proof_challenge_id IS NOT NULL AND expected_phone IS NOT NULL));

-- Written in the same transaction that deletes a user. Lets a client whose
-- deletion response was lost prove the deletion happened (user UUID plus the
-- hashed deletion challenge id) instead of inferring it from a 401/404.
-- Holds no phone number; rows are pruned after 30 days.
CREATE TABLE IF NOT EXISTS account_deletion_receipts (
    user_id      UUID        PRIMARY KEY,
    receipt_hash TEXT        NOT NULL,
    deleted_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_account_deletion_receipts_deleted_at
    ON account_deletion_receipts (deleted_at);
