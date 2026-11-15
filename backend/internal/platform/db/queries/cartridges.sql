-- name: CartridgePublishLock :exec
SELECT pg_advisory_xact_lock(1070401);
-- name: CountCartridges :one
SELECT count(*) FROM cartridges;
-- name: GetCartridge :one
SELECT * FROM cartridges WHERE id = @id;
-- name: InsertCartridge :exec
INSERT INTO cartridges (id, required_plan) VALUES (@id, @required_plan);
-- name: GetCartridgeVersion :one
SELECT v.*, c.required_plan FROM cartridge_versions v JOIN cartridges c ON c.id = v.cartridge_id
WHERE v.cartridge_id = @cartridge_id AND v.version = @version;
-- name: LatestCartridgeVersion :one
SELECT * FROM cartridge_versions WHERE cartridge_id = @cartridge_id ORDER BY version DESC LIMIT 1;
-- name: InsertCartridgeVersion :exec
INSERT INTO cartridge_versions(cartridge_id, version, title, word_count, sha256, document)
VALUES (@cartridge_id, @version, @title, @word_count, @sha256, @document);
-- name: ListCartridgeEntries :many
SELECT * FROM cartridge_entries WHERE cartridge_id = @cartridge_id ORDER BY entry_id;
-- name: InsertCartridgeEntry :exec
INSERT INTO cartridge_entries(cartridge_id, entry_id, first_version) VALUES (@cartridge_id, @entry_id, @first_version);
-- name: ListCartridgeCatalog :many
SELECT c.id, c.required_plan, v.version, v.title, v.word_count, v.sha256,
       COALESCE(i.installed_version, 0)::integer AS installed_version
FROM cartridges c
JOIN LATERAL (SELECT * FROM cartridge_versions WHERE cartridge_id = c.id ORDER BY version DESC LIMIT 1) v ON true
LEFT JOIN cartridge_installations i ON i.cartridge_id = c.id AND i.user_id = @user_id
ORDER BY c.id;
-- name: GetCartridgeInstallation :one
SELECT installed_version FROM cartridge_installations WHERE user_id = @user_id AND cartridge_id = @cartridge_id;
-- name: SetCartridgeInstallation :exec
INSERT INTO cartridge_installations(user_id, cartridge_id, installed_version) VALUES (@user_id, @cartridge_id, @installed_version)
ON CONFLICT (user_id, cartridge_id) DO UPDATE SET installed_version = GREATEST(cartridge_installations.installed_version, EXCLUDED.installed_version);
-- name: ListCartridgeInstallations :many
SELECT cartridge_id, installed_version FROM cartridge_installations WHERE user_id = @user_id ORDER BY cartridge_id;
-- name: DeleteCartridgeInstallations :exec
DELETE FROM cartridge_installations WHERE user_id = @user_id;
