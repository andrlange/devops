# PetClinic AI Companion — Design Specification

**Date:** 2026-03-22
**Status:** Draft
**App:** demos/petclinic (Spring Boot 4.0.4 + Kotlin 2.3.10)

## Overview

Extend the PetClinic demo with an AI companion that answers veterinary health questions. The AI uses a local Ollama instance (Llama 3.1 8B) with a RAG approach based on PostgreSQL Full-Text Search — no pgvector, no additional services required.

## Goals

- Provide AI-powered veterinary advice across four domains: general health, pet-specific care, appointment prep/aftercare, and emergency triage
- Demonstrate RAG pattern using only PostgreSQL FTS (no vector database)
- Connect to a local Ollama instance with configurable URL (handles variable WiFi IPs)
- Persist AI settings and pet-specific chat history in the existing PostgreSQL database
- Toggle AI features on/off via the UI menu, with all state persisted across restarts

## Non-Goals

- Replace professional veterinary advice (disclaimer required)
- Run Ollama inside the Kubernetes cluster
- Use pgvector or any external vector store
- Build a standalone API — this extends the existing Thymeleaf MVC app

## Architecture

### Components

```
Browser (Thymeleaf + SockJS/STOMP)
  │
  ├── HTTP ──────── AiSettingsController (REST + Thymeleaf)
  │                   └── GET/POST /ai/settings
  │
  └── WebSocket ─── AiChatController (STOMP message handler)
                      ├── /app/chat.send → VetKnowledgeService → OllamaChatService
                      └── /topic/chat.{sessionId} (streaming response)
                            │
              ┌─────────────┼──────────────┐
              │             │              │
         PostgreSQL    PostgreSQL      Ollama (local)
         (FTS query)   (chat history)  (LLM inference)
```

### Tech Stack Additions

| Component | Version | Purpose |
|-----------|---------|---------|
| Spring AI | 2.0.0-M3 | Ollama ChatClient, prompt templating |
| spring-boot-starter-websocket | (Boot managed) | STOMP/SockJS WebSocket support |
| SockJS + STOMP.js | Client libs | Browser WebSocket client with fallback |

### Network Path

The app runs inside the Lima VM (K3s pod). To reach Ollama on the Mac host:

- **vzNAT Gateway IP `192.168.64.1`** is always constant regardless of WiFi network
- Default Ollama URL: `http://192.168.64.1:11434`
- Ollama must be started with: `OLLAMA_HOST=0.0.0.0 ollama serve`

The user can override this URL in the AI Settings page.

## Data Model

Three new tables, added via Flyway migrations V3–V5.

### V3 — ai_settings

Singleton row storing the AI configuration. Survives app restarts.

```sql
CREATE TABLE ai_settings (
    id         BIGINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled    BOOLEAN NOT NULL DEFAULT FALSE,
    ollama_url VARCHAR(500),
    model_name VARCHAR(200),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO ai_settings (id, enabled) VALUES (1, FALSE);
```

### V4 — vet_knowledge

Veterinary knowledge base with PostgreSQL Full-Text Search. No extensions required — `tsvector` and GIN indexes are built into PostgreSQL.

```sql
CREATE TABLE vet_knowledge (
    id            BIGSERIAL PRIMARY KEY,
    category      VARCHAR(100) NOT NULL,
    pet_type      VARCHAR(50),  -- NULL means applicable to all types
    title         VARCHAR(300) NOT NULL,
    content       TEXT NOT NULL,
    search_vector TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('english', title || ' ' || content)
    ) STORED
);

CREATE INDEX idx_vet_knowledge_fts ON vet_knowledge USING GIN (search_vector);
CREATE INDEX idx_vet_knowledge_category ON vet_knowledge (category);
CREATE INDEX idx_vet_knowledge_pet_type ON vet_knowledge (pet_type);
```

**Categories:** `general_health`, `nutrition`, `vaccination`, `emergency`, `post_visit`, `senior_care`

**Seed data:** ~60 articles covering all 8 pet types (Dog, Cat, Hamster, Guinea Pig, Rabbit, Bird, Turtle, Snake) across all categories.

### V5 — ai_chat_messages

Pet-specific chat history. Only pet-context chats are persisted; general chats are session-only.

```sql
CREATE TABLE ai_chat_messages (
    id             BIGSERIAL PRIMARY KEY,
    pet_id         BIGINT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    session_id     VARCHAR(100) NOT NULL,
    role           VARCHAR(20) NOT NULL,  -- 'user' | 'assistant'
    content        TEXT NOT NULL,
    knowledge_refs TEXT,                  -- JSON array of matched article titles
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_chat_pet_id ON ai_chat_messages (pet_id);
CREATE INDEX idx_chat_session ON ai_chat_messages (session_id);
CREATE INDEX idx_chat_created ON ai_chat_messages (created_at DESC);
```

## RAG Retrieval Flow

1. User sends a question (optionally with pet context)
2. Extract search terms: split on whitespace, remove common stop words, join with `&` for `to_tsquery`. No LLM-assisted extraction — keep it simple.
3. FTS query against `vet_knowledge` with `ts_rank` scoring, filtered by `pet_type` if applicable
4. Take top 3 articles by rank
5. Build prompt: system instructions + article content + pet data (if pet chat) + user question
6. Stream response from Ollama via Spring AI ChatClient
7. Push tokens via STOMP WebSocket to `/topic/chat.{sessionId}`
8. For pet chats: persist completed messages to `ai_chat_messages`

### FTS Query Pattern

```sql
SELECT title, content, ts_rank(search_vector, query) AS rank
FROM vet_knowledge, to_tsquery('english', 'dog & limping & senior') query
WHERE search_vector @@ query
  AND (pet_type IS NULL OR pet_type = 'Dog')
ORDER BY rank DESC
LIMIT 3;
```

If no FTS results are found, the LLM answers from its own knowledge with a note that no clinic-specific information was available.

## UI Design

### AI Toggle in Navbar

- **AI button** always visible in the navbar with ON/OFF badge
- First click when unconfigured → redirect to AI Settings
- When ON: "AI Chat" and "AI Settings" menu items appear, model badge shown in navbar
- When OFF: all AI elements hidden, app behaves as before

### AI Settings Page (`/ai/settings`)

- Ollama Server URL input (default: `http://192.168.64.1:11434`)
- Model dropdown — populated dynamically from Ollama API (`GET /api/tags`)
- Enable/Disable radio buttons
- "Test Connection" button with status feedback
- All settings persisted in `ai_settings` table

### Dedicated Chat Page (`/ai/chat`)

- Left sidebar: topic categories (General Health, Nutrition, Vaccinations, Emergency, Post-Visit Care) and quick question templates
- Right: chat message area with streaming responses
- AI avatar with paw icon, user messages right-aligned
- RAG source attribution below AI responses ("Based on: Senior Dog Care, Joint Health...")
- Disclaimer: "Not a substitute for professional veterinary care"

### Pet Detail Chat Widget (`/pets/{id}`)

- "Ask AI about {petName}" button on pet detail page (only visible when AI enabled)
- Expandable chat panel with context banner (pet type, age, last visit, total visits)
- AI automatically receives pet data and visit history as context
- Previous conversations listed as clickable tags below the chat panel
- Chat history persistent per pet

### Visit Detail AI Tips

- When AI is enabled, visit detail pages show an "AI Tips" section
- Contextual advice based on visit type (e.g., post-dental-cleaning care)

## Spring Components

### New Kotlin Classes

```
src/main/kotlin/cool/cfapps/petclinic/
├── ai/
│   ├── AiSettings.kt                 # JPA entity
│   ├── AiSettingsRepository.kt       # JPA repository
│   ├── AiSettingsController.kt       # Settings page + REST
│   ├── AiChatMessage.kt              # JPA entity
│   ├── AiChatMessageRepository.kt    # JPA repository
│   ├── AiChatController.kt           # STOMP message handler
│   ├── VetKnowledge.kt               # JPA entity
│   ├── VetKnowledgeRepository.kt     # JPA repository + FTS queries
│   ├── VetKnowledgeService.kt        # FTS retrieval logic
│   ├── OllamaChatService.kt          # Spring AI ChatClient wrapper
│   └── WebSocketConfig.kt            # STOMP/SockJS configuration
```

### New Templates

```
src/main/resources/templates/
├── ai/
│   ├── settings.html                 # AI configuration page
│   └── chat.html                     # Dedicated chat page
├── fragments/
│   └── ai-chat-widget.html           # Reusable pet chat widget fragment
```

### New Static Assets

```
src/main/resources/static/
├── js/
│   └── ai-chat.js                    # SockJS/STOMP client, message rendering
```

### WebSocket Configuration

- STOMP endpoint: `/ws` with SockJS fallback
- Application destination prefix: `/app`
- Broker prefix: `/topic`
- Send destination: `/app/chat.send`
- Subscribe destination: `/topic/chat.{sessionId}`
- Session ID: UUID generated per chat conversation (new UUID when opening a new chat, reused when continuing an existing pet chat session)

### OllamaChatService

- Constructs `OllamaChatModel` manually (not via auto-configuration) since the Ollama URL is dynamic from `ai_settings` DB table
- Rebuilds the `OllamaChatModel` and `ChatClient` when settings change (URL or model update)
- System prompt includes: veterinarian role, disclaimer requirement, RAG context injection point
- Streams response via `Flux<String>`, pushed to WebSocket by `AiChatController`

### GlobalModelAttributes Extension

The existing `GlobalModelAttributes.kt` will be extended to expose `aiEnabled` and `aiModel` to all Thymeleaf templates, controlling visibility of AI elements across the app.

## Deployment

### CF Context Handling

The `deploy-cf.sh` script must safely switch CF context:

```bash
# Save current context
PREV_ORG=$(cf target | grep "org:" | awk '{print $2}')
PREV_SPACE=$(cf target | grep "space:" | awk '{print $2}')

# Switch to demo/spring
cf target -o demo -s spring

# ... build and push ...

# Restore (also via trap EXIT for failure cases)
cf target -o "$PREV_ORG" -s "$PREV_SPACE"
```

### manifest.yml Updates

No changes needed — the existing manifest already configures `petclinic-db` as a service binding. The new tables are created automatically via Flyway migrations.

### build.gradle.kts Additions

```kotlin
val springAiVersion = "2.0.0-M3"
implementation("org.springframework.ai:spring-ai-ollama-spring-boot-starter:$springAiVersion")
implementation("org.springframework.boot:spring-boot-starter-websocket")
```

Spring AI milestone repository must be added:

```kotlin
repositories {
    mavenCentral()
    maven { url = uri("https://repo.spring.io/milestone") }
}
```

### Ollama Setup

Ollama runs locally on the Mac, not in the cluster:

```bash
# Install model
ollama pull llama3.1:8b

# Start with all-interfaces binding
OLLAMA_HOST=0.0.0.0 ollama serve
```

## Knowledge Base Content

~60 seed articles distributed across categories:

| Category | Articles | Content |
|----------|----------|---------|
| general_health | ~12 | Common symptoms per species, when to see a vet, preventive care |
| nutrition | ~12 | Diet per species & age, toxic foods, weight management |
| vaccination | ~8 | Core vaccines, schedules by age, booster reminders, side effects |
| emergency | ~10 | Poisoning, injuries, breathing difficulties, triage guidance |
| post_visit | ~8 | Post-surgery recovery, medication, dental aftercare, wound care |
| senior_care | ~10 | Aging signs, joint health, cognitive decline, end-of-life care |

Articles are written in English, covering all 8 pet types. Each article is 200-400 words, optimized for FTS retrieval (clear headings, specific terminology).

## Error Handling

- **Ollama unreachable:** Show connection error in chat, suggest checking AI Settings
- **No FTS results:** LLM answers from own knowledge with disclaimer note
- **WebSocket disconnect:** SockJS falls back to long-polling; reconnect indicator in UI
- **Model not found:** Error message with link to AI Settings to select a different model
- **Streaming interrupted:** Partial message displayed with "Response interrupted" note

## Security Considerations

- Ollama URL is stored server-side in PostgreSQL, not exposed to the browser
- No authentication on Ollama (local development tool) — document this as a demo limitation
- Chat input sanitized server-side before prompt injection into LLM context
- AI responses rendered with HTML escaping in Thymeleaf
