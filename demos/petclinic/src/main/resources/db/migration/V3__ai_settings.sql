CREATE TABLE ai_settings (
    id         BIGINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled    BOOLEAN NOT NULL DEFAULT FALSE,
    ollama_url VARCHAR(500) DEFAULT 'http://192.168.64.1:11434',
    model_name VARCHAR(200) DEFAULT 'llama3.1:8b',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO ai_settings (id, enabled) VALUES (1, FALSE);
