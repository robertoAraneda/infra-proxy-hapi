-- init-proxy-db.sql
-- Initialize FHIR proxy database with audit logging capabilities

-- Create loguser only if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'loguser') THEN
        CREATE USER loguser WITH PASSWORD 'logpass';
        RAISE NOTICE 'Created user loguser';
    ELSE
        RAISE NOTICE 'User loguser already exists';
    END IF;
END
$$;

-- Grant permissions to loguser on the current database (proxy database)
GRANT CONNECT ON DATABASE CURRENT_DATABASE TO loguser;
GRANT USAGE ON SCHEMA public TO loguser;
GRANT CREATE ON SCHEMA public TO loguser;

-- Create audit logs table with enhanced fields
CREATE TABLE IF NOT EXISTS audit_logs (
    id SERIAL PRIMARY KEY,
    request_id VARCHAR(255) NOT NULL,
    user_id VARCHAR(255),
    client_id VARCHAR(255),
    username VARCHAR(255),
    client_ip INET NOT NULL,
    method VARCHAR(10) NOT NULL,
    endpoint TEXT NOT NULL,
    full_url TEXT NOT NULL,
    fhir_resource VARCHAR(100),
    resource_id VARCHAR(255),
    operation VARCHAR(50),
    status_code INTEGER NOT NULL,
    response_time_ms BIGINT NOT NULL,
    data_accessed BOOLEAN DEFAULT FALSE,
    phi_accessed BOOLEAN DEFAULT FALSE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    user_agent TEXT,
    session_id VARCHAR(255),
    request_body JSONB,
    response_body JSONB,
    jwt_claims JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for better performance (using IF NOT EXISTS to prevent conflicts)
DO $$
BEGIN
    -- Check and create indexes only if they don't exist
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_timestamp') THEN
        CREATE INDEX idx_audit_logs_timestamp ON audit_logs(timestamp DESC);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_resource') THEN
        CREATE INDEX idx_audit_logs_resource ON audit_logs(fhir_resource);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_phi') THEN
        CREATE INDEX idx_audit_logs_phi ON audit_logs(phi_accessed) WHERE phi_accessed = true;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_status') THEN
        CREATE INDEX idx_audit_logs_status ON audit_logs(status_code) WHERE status_code >= 400;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_user_id') THEN
        CREATE INDEX idx_audit_logs_user_id ON audit_logs(user_id) WHERE user_id IS NOT NULL;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_client_id') THEN
        CREATE INDEX idx_audit_logs_client_id ON audit_logs(client_id) WHERE client_id IS NOT NULL;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_operation') THEN
        CREATE INDEX idx_audit_logs_operation ON audit_logs(operation);
    END IF;
    
    -- JSONB indexes for searching within JSON fields
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_jwt_claims') THEN
        CREATE INDEX idx_audit_logs_jwt_claims ON audit_logs USING GIN (jwt_claims);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_request_body') THEN
        CREATE INDEX idx_audit_logs_request_body ON audit_logs USING GIN (request_body);
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_audit_logs_response_body') THEN
        CREATE INDEX idx_audit_logs_response_body ON audit_logs USING GIN (response_body);
    END IF;
END
$$;

-- Grant all necessary permissions to loguser
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO loguser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO loguser;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO loguser;

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO loguser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO loguser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO loguser;

-- Create enhanced views for analytics and monitoring
CREATE OR REPLACE VIEW daily_stats AS
SELECT
    DATE(timestamp) as date,
    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE status_code < 400) as successful_requests,
    COUNT(*) FILTER (WHERE status_code >= 400) as failed_requests,
    COUNT(*) FILTER (WHERE phi_accessed = true) as phi_accesses,
    COUNT(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL) as unique_users,
    COUNT(DISTINCT client_id) FILTER (WHERE client_id IS NOT NULL) as unique_clients,
    COUNT(*) FILTER (WHERE request_body IS NOT NULL) as requests_with_body,
    COUNT(*) FILTER (WHERE operation = 'validate') as validate_operations,
    ROUND(AVG(response_time_ms), 2) as avg_response_time_ms
FROM audit_logs
GROUP BY DATE(timestamp)
ORDER BY date DESC;

CREATE OR REPLACE VIEW resource_stats AS
SELECT
    fhir_resource,
    operation,
    COUNT(*) as request_count,
    ROUND(AVG(response_time_ms), 2) as avg_response_time_ms,
    COUNT(*) FILTER (WHERE status_code >= 400) as error_count,
    COUNT(*) FILTER (WHERE phi_accessed = true) as phi_access_count,
    COUNT(DISTINCT user_id) FILTER (WHERE user_id IS NOT NULL) as unique_users,
    COUNT(*) FILTER (WHERE request_body IS NOT NULL) as requests_with_body
FROM audit_logs
WHERE fhir_resource IS NOT NULL
GROUP BY fhir_resource, operation
ORDER BY request_count DESC;

CREATE OR REPLACE VIEW recent_errors AS
SELECT
    timestamp,
    request_id,
    method,
    endpoint,
    full_url,
    status_code,
    client_ip,
    user_id,
    username,
    client_id,
    fhir_resource,
    operation,
    response_time_ms,
    CASE
        WHEN response_body IS NOT NULL THEN
            LEFT(response_body::text, 200) || CASE WHEN LENGTH(response_body::text) > 200 THEN '...' ELSE '' END
        ELSE NULL
    END as error_snippet
FROM audit_logs
WHERE status_code >= 400
  AND timestamp >= NOW() - INTERVAL '24 hours'
ORDER BY timestamp DESC;

CREATE OR REPLACE VIEW user_activity AS
SELECT
    user_id,
    username,
    client_id,
    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE phi_accessed = true) as phi_accesses,
    COUNT(DISTINCT fhir_resource) as resources_accessed,
    MIN(timestamp) as first_seen,
    MAX(timestamp) as last_seen,
    ROUND(AVG(response_time_ms), 2) as avg_response_time_ms
FROM audit_logs
WHERE user_id IS NOT NULL
  AND timestamp >= NOW() - INTERVAL '7 days'
GROUP BY user_id, username, client_id
ORDER BY total_requests DESC;

CREATE OR REPLACE VIEW jwt_analysis AS
SELECT
    jwt_claims->>'issuer' as issuer,
    jwt_claims->>'client_id' as client_id,
    jsonb_array_length(COALESCE(jwt_claims->'roles', '[]'::jsonb)) as role_count,
    jsonb_array_length(COALESCE(jwt_claims->'scopes', '[]'::jsonb)) as scope_count,
    COUNT(*) as request_count,
    COUNT(DISTINCT user_id) as unique_users
FROM audit_logs
WHERE jwt_claims IS NOT NULL
  AND timestamp >= NOW() - INTERVAL '24 hours'
GROUP BY jwt_claims->>'issuer', jwt_claims->>'client_id',
         jsonb_array_length(COALESCE(jwt_claims->'roles', '[]'::jsonb)),
         jsonb_array_length(COALESCE(jwt_claims->'scopes', '[]'::jsonb))
ORDER BY request_count DESC;

-- Grant view permissions to loguser
GRANT SELECT ON daily_stats TO loguser;
GRANT SELECT ON resource_stats TO loguser;
GRANT SELECT ON recent_errors TO loguser;
GRANT SELECT ON user_activity TO loguser;
GRANT SELECT ON jwt_analysis TO loguser;

-- Insert sample data for demo purposes (only if the table is empty)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM audit_logs LIMIT 1) THEN
        INSERT INTO audit_logs (
            request_id, client_ip, method, endpoint, full_url, fhir_resource, operation,
            status_code, response_time_ms, data_accessed, phi_accessed, timestamp, user_agent,
            user_id, client_id, username, session_id, request_body, jwt_claims
        ) VALUES
            (
                'demo-001', '127.0.0.1', 'GET', '/fhir/Patient/1',
                'http://localhost:8080/fhir/Patient/1', 'Patient', 'read',
                200, 45, true, true, NOW() - INTERVAL '1 hour', 'Demo-Client/1.0',
                'user123', 'client-app-1', 'john.doe', 'session-abc123',
                NULL,
                '{"user_id": "user123", "client_id": "client-app-1", "username": "john.doe", "roles": ["clinician"], "scopes": ["fhir:read"]}'::jsonb
            ),
            (
                'demo-002', '127.0.0.1', 'GET', '/fhir/Patient?name=John',
                'http://localhost:8080/fhir/Patient?name=John&_count=10', 'Patient', 'search',
                200, 120, true, true, NOW() - INTERVAL '30 minutes', 'Demo-Client/1.0',
                'user456', 'client-app-2', 'jane.smith', 'session-def456',
                NULL,
                '{"user_id": "user456", "client_id": "client-app-2", "username": "jane.smith", "roles": ["nurse"], "scopes": ["fhir:read", "fhir:search"]}'::jsonb
            ),
            (
                'demo-003', '127.0.0.1', 'POST', '/fhir/Observation',
                'http://localhost:8080/fhir/Observation', 'Observation', 'create',
                201, 78, true, true, NOW() - INTERVAL '15 minutes', 'Demo-Client/1.0',
                'user123', 'client-app-1', 'john.doe', 'session-abc123',
                '{"resourceType": "Observation", "status": "final", "code": {"coding": [{"system": "http://loinc.org", "code": "15074-8"}]}}'::jsonb,
                '{"user_id": "user123", "client_id": "client-app-1", "username": "john.doe", "roles": ["clinician"], "scopes": ["fhir:read", "fhir:write"]}'::jsonb
            ),
            (
                'demo-004', '127.0.0.1', 'GET', '/fhir/Patient/999',
                'http://localhost:8080/fhir/Patient/999', 'Patient', 'read',
                404, 23, false, false, NOW() - INTERVAL '5 minutes', 'Demo-Client/1.0',
                'user789', 'client-app-3', 'admin.user', 'session-ghi789',
                NULL,
                '{"user_id": "user789", "client_id": "client-app-3", "username": "admin.user", "roles": ["admin"], "scopes": ["fhir:*"]}'::jsonb
            ),
            (
                'demo-005', '127.0.0.1', 'POST', '/fhir/Patient/$validate',
                'http://localhost:8080/fhir/Patient/$validate', 'Patient', 'validate',
                200, 67, false, false, NOW() - INTERVAL '2 minutes', 'Demo-Client/1.0',
                'user456', 'client-app-2', 'jane.smith', 'session-def456',
                '{"resourceType": "Patient", "name": [{"family": "Test", "given": ["Demo"]}]}'::jsonb,
                '{"user_id": "user456", "client_id": "client-app-2", "username": "jane.smith", "roles": ["nurse"], "scopes": ["fhir:read", "fhir:validate"]}'::jsonb
            );
        
        RAISE NOTICE 'Inserted sample audit log data';
    ELSE
        RAISE NOTICE 'Audit logs table already contains data, skipping sample data insertion';
    END IF;
END
$$;