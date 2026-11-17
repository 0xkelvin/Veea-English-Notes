-- Re-run after each successful migration and before starting the API.
\set ON_ERROR_STOP on
BEGIN;
GRANT USAGE ON SCHEMA public TO veea_api, veea_maintenance;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO veea_api, veea_maintenance;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO veea_api, veea_maintenance;
REVOKE UPDATE, DELETE ON audit_events FROM veea_api;
REVOKE INSERT, UPDATE, DELETE ON apple_iap_control FROM veea_api, veea_maintenance;
REVOKE ALL ON goose_db_version FROM veea_api, veea_maintenance;
COMMIT;
