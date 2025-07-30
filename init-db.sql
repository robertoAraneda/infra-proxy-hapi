-- Initialize Keycloak database
-- This script runs automatically when the PostgreSQL container starts for the first time

-- The database and user are already created by the POSTGRES_DB, POSTGRES_USER, and POSTGRES_PASSWORD environment variables
-- This script ensures proper permissions and extensions

-- Grant all privileges to the keycloak user on the keycloak database
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;

-- Connect to the keycloak database
\c keycloak;

-- Grant schema permissions
GRANT ALL ON SCHEMA public TO keycloak;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO keycloak;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO keycloak;

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO keycloak;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO keycloak;