-- Medical Reports Database Schema
-- Production-ready initialization script with separate schemas

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create dedicated schemas
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS keycloak;

-- Ensure connections default to the app schema for this database and role
-- so the backend (which uses unqualified table names) will target app schema
ALTER DATABASE medical_reports SET search_path TO app, public;
ALTER ROLE postgres SET search_path TO app, public;

-- Use app schema for all subsequent objects in this script
SET search_path TO app, public;

-- Create roles table
CREATE TABLE roles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(50) UNIQUE NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert default roles
INSERT INTO roles (name, description) VALUES 
    ('admin', 'System administrator with full access'),
    ('doctor', 'Medical professional who can create and edit reports'),
    ('researcher', 'Can view finalized reports and export data'),
    ('observer', 'Read-only access to finalized reports');



-- Create users table
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    role_id UUID NOT NULL REFERENCES roles(id),
    keycloak_user_id TEXT UNIQUE,
    local_password VARCHAR(255), -- bcrypt hashed, nullable for SSO-only users
    is_active BOOLEAN DEFAULT true,
    last_login TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CHECK (local_password IS NOT NULL OR keycloak_user_id IS NOT NULL)
);

-- Create sessions table
CREATE TABLE sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token TEXT UNIQUE NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ip_address INET,
    user_agent TEXT
);

-- Create reports table
CREATE TABLE reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    study_instance_uid VARCHAR(255) UNIQUE NOT NULL,
    patient_id VARCHAR(255) NOT NULL,
    patient_name VARCHAR(255),
    patient_dob DATE,
    study_date DATE,
    study_description TEXT,
    modality VARCHAR(10),
    doctor_id UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    finalized_at TIMESTAMP,
    tags TEXT[] DEFAULT '{}' -- for search and categorization
);

-- Create report_versions table
CREATE TABLE report_versions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    report_id UUID NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
    version_no INTEGER NOT NULL,
    findings TEXT NOT NULL,
    impression TEXT NOT NULL,
    template_used VARCHAR(255),
    generated_by_ai BOOLEAN DEFAULT false,
    ai_model_used VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(report_id, version_no)
);

-- Ad-hoc uploads for BlueLight viewer
CREATE TABLE uploads (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stored_filename TEXT NOT NULL,
    original_filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    file_size BIGINT NOT NULL,
    modality VARCHAR(32),
    hash TEXT,
    status VARCHAR(16) NOT NULL DEFAULT 'ready',
    source VARCHAR(32) NOT NULL DEFAULT 'upload',
    thumbnail_key TEXT,
    converted_image_path TEXT,
    dicom_metadata JSONB,
    is_dicom BOOLEAN DEFAULT FALSE,
    study_instance_uid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_uploads_user_id ON uploads(user_id);
CREATE INDEX IF NOT EXISTS idx_uploads_status ON uploads(status);
CREATE INDEX IF NOT EXISTS idx_uploads_created_at ON uploads(created_at);


CREATE TABLE IF NOT EXISTS file_metadata (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    file_id UUID NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
    study_uid TEXT,
    series_uid TEXT,
    patient_id TEXT,
    modality TEXT,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create _configs table
CREATE TABLE llm_configs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT, -- Custom display name
    model_name VARCHAR(100) NOT NULL,
    api_url TEXT NOT NULL,
    api_key TEXT NOT NULL,
    prompt TEXT,
    priority INTEGER NOT NULL DEFAULT 100,
    enabled BOOLEAN DEFAULT true,
    max_tokens INTEGER DEFAULT 2000,
    temperature DECIMAL(3,2) DEFAULT 0.7,
    top_p DECIMAL(3,2) DEFAULT 1.0,
    created_by UUID REFERENCES users(id),
    updated_by UUID REFERENCES users(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create llm_pipelines table (two-stage LLM pipelines)
CREATE TABLE IF NOT EXISTS llm_pipelines (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,
    enabled BOOLEAN DEFAULT true,

    -- Stage 1 configuration
    stage1_model_name VARCHAR(100) NOT NULL,
    stage1_api_url TEXT NOT NULL,
    stage1_api_key TEXT NOT NULL,
    stage1_prompt TEXT,
    stage1_max_tokens INTEGER DEFAULT 2000,
    stage1_temperature DECIMAL(3,2) DEFAULT 0.7,
    stage1_top_p DECIMAL(3,2) DEFAULT 1.0,
    stage1_include_image BOOLEAN DEFAULT true,

    -- Stage 2 configuration
    stage2_model_name VARCHAR(100) NOT NULL,
    stage2_api_url TEXT NOT NULL,
    stage2_api_key TEXT NOT NULL,
    stage2_prompt TEXT,
    stage2_max_tokens INTEGER DEFAULT 2000,
    stage2_temperature DECIMAL(3,2) DEFAULT 0.7,
    stage2_top_p DECIMAL(3,2) DEFAULT 1.0,
    stage2_include_image BOOLEAN DEFAULT false,

    created_by UUID REFERENCES users(id),
    updated_by UUID REFERENCES users(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create pacs_config table (singleton)
CREATE TABLE pacs_config (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pacs_url TEXT NOT NULL,
    auth_type VARCHAR(20) NOT NULL DEFAULT 'none', -- 'none', 'basic', 'token'
    credentials JSONB,
    connection_timeout INTEGER DEFAULT 30,
    query_timeout INTEGER DEFAULT 60,
    updated_by UUID REFERENCES users(id),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Seed default PACS (DICOMweb) settings for development
INSERT INTO pacs_config (pacs_url, auth_type, credentials, connection_timeout, query_timeout)
VALUES ('https://raccoon.dicom.org.tw/dicom-web/', 'none', NULL, 30, 60);

-- Create rag_config table
CREATE TABLE rag_config (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    rag_url TEXT NOT NULL,
    enabled BOOLEAN DEFAULT false,
    api_key TEXT,
    timeout INTEGER DEFAULT 30,
    confidence_threshold DECIMAL(3,2) DEFAULT 0.8,
    updated_by UUID REFERENCES users(id),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create system_settings table (singleton)
CREATE TABLE system_settings (
    id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    system_name TEXT NOT NULL DEFAULT 'Medical Reports',
    max_concurrent_tasks INTEGER NOT NULL DEFAULT 5,
    backup_frequency TEXT NOT NULL DEFAULT 'daily',
    updated_by UUID REFERENCES users(id),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Seed a single row
INSERT INTO system_settings (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Create audit_logs table
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id),
    action VARCHAR(100) NOT NULL,
    target_type VARCHAR(50), -- 'report', 'user', 'config', etc.
    target_id UUID,
    details JSONB,
    ip_address INET,
    user_agent TEXT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for performance
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_role_id ON users(role_id);
CREATE INDEX idx_users_is_active ON users(is_active);
CREATE INDEX idx_sessions_user_id_expires_at ON sessions(user_id, expires_at);
CREATE INDEX idx_sessions_token ON sessions USING HASH(token);
CREATE INDEX idx_sessions_user_id ON sessions(user_id);
CREATE INDEX idx_sessions_expires_at ON sessions(expires_at);
CREATE INDEX idx_reports_study_uid ON reports(study_instance_uid);
CREATE INDEX idx_reports_patient_id ON reports(patient_id);
CREATE INDEX idx_reports_doctor_id ON reports(doctor_id);
CREATE INDEX idx_reports_created_at ON reports(created_at);
CREATE INDEX idx_reports_finalized_at ON reports(finalized_at);
CREATE INDEX idx_reports_tags ON reports USING GIN(tags);
CREATE INDEX idx_report_versions_report_id ON report_versions(report_id);
CREATE INDEX idx_report_versions_created_at ON report_versions(created_at);
CREATE INDEX idx_llm_configs_enabled_priority ON llm_configs(enabled, priority);
CREATE INDEX idx_llm_pipelines_enabled_priority ON llm_pipelines(enabled, priority);
CREATE INDEX idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX idx_audit_logs_timestamp ON audit_logs(timestamp);
CREATE INDEX idx_audit_logs_action ON audit_logs(action);
CREATE INDEX idx_audit_logs_target ON audit_logs(target_type, target_id);

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Add updated_at triggers
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_roles_updated_at BEFORE UPDATE ON roles 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_reports_updated_at BEFORE UPDATE ON reports 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_llm_configs_updated_at BEFORE UPDATE ON llm_configs 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_llm_pipelines_updated_at BEFORE UPDATE ON llm_pipelines
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_pacs_config_updated_at BEFORE UPDATE ON pacs_config 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_rag_config_updated_at BEFORE UPDATE ON rag_config 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_system_settings_updated_at BEFORE UPDATE ON system_settings 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Default local users are seeded by backend startup code, not by this schema file.

-- Note: Keycloak will manage its own objects in the "keycloak" schema.
-- We only ensure the schema exists; Keycloak is configured via KC_DB_SCHEMA.

-- No default LLM configuration is seeded by default.

-- Create function to get latest report version
CREATE OR REPLACE FUNCTION get_latest_report_version(report_uuid UUID)
RETURNS TABLE(
    id UUID,
    version_no INTEGER,
    findings TEXT,
    impression TEXT,
    template_used VARCHAR(255),
    generated_by_ai BOOLEAN,
    ai_model_used VARCHAR(100),
    created_at TIMESTAMP
) AS $$
BEGIN
    RETURN QUERY
    SELECT rv.id, rv.version_no, rv.findings, rv.impression,
           rv.template_used, rv.generated_by_ai, rv.ai_model_used, rv.created_at
    FROM report_versions rv
    WHERE rv.report_id = report_uuid
    ORDER BY rv.version_no DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- Create function to check user permissions
CREATE OR REPLACE FUNCTION user_can_access_report(user_uuid UUID, report_uuid UUID)
RETURNS BOOLEAN AS $$
DECLARE
    user_role VARCHAR(50);
    report_finalized BOOLEAN;
BEGIN
    -- Get user role
    SELECT r.name INTO user_role
    FROM users u
    JOIN roles r ON u.role_id = r.id
    WHERE u.id = user_uuid;
    
    -- Get report finalization status
    SELECT (finalized_at IS NOT NULL) INTO report_finalized
    FROM reports
    WHERE id = report_uuid;
    
    -- Admin and Doctor can see all reports
    IF user_role IN ('admin', 'doctor') THEN
        RETURN true;
    END IF;
    
    -- Researcher and Observer can only see finalized reports
    IF user_role IN ('researcher', 'observer') AND report_finalized THEN
        RETURN true;
    END IF;
    
    RETURN false;
END;
$$ LANGUAGE plpgsql;

-- Create view for report summary
CREATE VIEW report_summary AS
SELECT 
    r.id,
    r.study_instance_uid,
    r.patient_id,
    r.patient_name,
    r.study_date,
    r.study_description,
    r.modality,
    r.doctor_id,
    u.name as doctor_name,
    r.created_at,
    r.updated_at,
    r.finalized_at,
    r.tags,
    (SELECT COUNT(*) FROM report_versions rv WHERE rv.report_id = r.id) as version_count,
    (r.finalized_at IS NOT NULL) as is_finalized
FROM reports r
JOIN users u ON r.doctor_id = u.id;

-- Grant permissions
GRANT USAGE ON SCHEMA public TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO postgres;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO postgres;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO postgres;
