-- Fresh production volume only. Credentials are read from the private container environment.
\set ON_ERROR_STOP on
\set ECHO none
\getenv migration_password VEEA_PROD_MIGRATION_PASSWORD
\getenv api_password VEEA_PROD_API_PASSWORD
\getenv maintenance_password VEEA_PROD_MAINTENANCE_PASSWORD
CREATE ROLE veea_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'migration_password';
CREATE ROLE veea_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'api_password';
CREATE ROLE veea_maintenance LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'maintenance_password';
ALTER DATABASE veea OWNER TO veea_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
