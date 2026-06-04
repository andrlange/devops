CREATE TABLE ai_chat_messages (
    id             BIGSERIAL PRIMARY KEY,
    pet_id         BIGINT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    session_id     VARCHAR(100) NOT NULL,
    role           VARCHAR(20) NOT NULL,
    content        TEXT NOT NULL,
    knowledge_refs TEXT,
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_chat_pet_id ON ai_chat_messages (pet_id);
CREATE INDEX idx_chat_session ON ai_chat_messages (session_id);
CREATE INDEX idx_chat_created ON ai_chat_messages (created_at DESC);
