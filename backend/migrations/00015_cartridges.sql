-- +goose Up
-- TRD 10: shared immutable catalog, cumulative entry identities and bounded owner watermarks.
CREATE TABLE IF NOT EXISTS cartridges (
    id text PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9_-]{0,47}$'),
    required_plan text NOT NULL CHECK (required_plan IN ('free', 'premium'))
);
CREATE TABLE IF NOT EXISTS cartridge_versions (
    cartridge_id text NOT NULL REFERENCES cartridges(id) ON DELETE RESTRICT,
    version integer NOT NULL CHECK (version > 0),
    title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 100),
    word_count integer NOT NULL CHECK (word_count BETWEEN 1 AND 200),
    sha256 text NOT NULL CHECK (sha256 ~ '^[a-f0-9]{64}$'),
    document bytea NOT NULL CHECK (octet_length(document) BETWEEN 1 AND 1048576),
    PRIMARY KEY (cartridge_id, version)
);
CREATE TABLE IF NOT EXISTS cartridge_entries (
    cartridge_id text NOT NULL,
    entry_id uuid NOT NULL,
    first_version integer NOT NULL,
    PRIMARY KEY (cartridge_id, entry_id),
    FOREIGN KEY (cartridge_id, first_version) REFERENCES cartridge_versions(cartridge_id, version) ON DELETE RESTRICT
);
CREATE TABLE IF NOT EXISTS cartridge_installations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    cartridge_id text NOT NULL,
    installed_version integer NOT NULL,
    PRIMARY KEY (user_id, cartridge_id),
    FOREIGN KEY (cartridge_id, installed_version) REFERENCES cartridge_versions(cartridge_id, version) ON DELETE RESTRICT
);
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION cartridge_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'published cartridge data is immutable';
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cartridges_immutable' AND tgrelid = 'cartridges'::regclass) THEN
      CREATE TRIGGER cartridges_immutable BEFORE UPDATE OR DELETE ON cartridges FOR EACH ROW EXECUTE FUNCTION cartridge_immutable();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cartridge_versions_immutable' AND tgrelid = 'cartridge_versions'::regclass) THEN
      CREATE TRIGGER cartridge_versions_immutable BEFORE UPDATE OR DELETE ON cartridge_versions FOR EACH ROW EXECUTE FUNCTION cartridge_immutable();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cartridge_entries_immutable' AND tgrelid = 'cartridge_entries'::regclass) THEN
      CREATE TRIGGER cartridge_entries_immutable BEFORE UPDATE OR DELETE ON cartridge_entries FOR EACH ROW EXECUTE FUNCTION cartridge_immutable();
    END IF;
END $$;
-- +goose StatementEnd
