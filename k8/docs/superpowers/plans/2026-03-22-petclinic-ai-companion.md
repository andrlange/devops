# PetClinic AI Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AI veterinary companion to the PetClinic demo using Spring AI + Ollama with PostgreSQL FTS for RAG retrieval and WebSocket streaming.

**Architecture:** Spring Boot 4.0.4 Kotlin app extended with Spring AI 2.0.0-M3 for Ollama communication. PostgreSQL Full-Text Search provides RAG context (no pgvector). STOMP over WebSocket (SockJS fallback) streams AI responses. AI features are toggled via a navbar button with settings persisted in DB.

**Tech Stack:** Spring AI 2.0.0-M3, spring-boot-starter-websocket, SockJS/STOMP.js, PostgreSQL tsvector/GIN, Ollama (Llama 3.1 8B)

**Spec:** `k8/docs/superpowers/specs/2026-03-22-petclinic-ai-companion-design.md`

---

## File Structure

### New Files

```
demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/
├── AiSettings.kt                    # JPA entity — singleton settings row
├── AiSettingsRepository.kt          # JPA repository for ai_settings
├── AiSettingsController.kt          # Settings page (Thymeleaf) + REST endpoints
├── VetKnowledge.kt                  # JPA entity — knowledge articles
├── VetKnowledgeRepository.kt        # JPA repository + native FTS queries
├── VetKnowledgeService.kt           # FTS retrieval, search term extraction, prompt building
├── AiChatMessage.kt                 # JPA entity — persistent pet chat messages
├── AiChatMessageRepository.kt       # JPA repository for chat history
├── OllamaChatService.kt             # Dynamic ChatClient construction, streaming
├── AiChatController.kt              # STOMP message handler + REST for chat history
└── WebSocketConfig.kt               # STOMP/SockJS endpoint configuration

demos/petclinic/src/main/resources/
├── db/migration/
│   ├── V3__ai_settings.sql          # ai_settings table + singleton row
│   ├── V4__vet_knowledge.sql        # vet_knowledge table + FTS index + seed data
│   └── V5__ai_chat_messages.sql     # ai_chat_messages table + indexes
├── templates/ai/
│   ├── settings.html                # AI configuration page
│   └── chat.html                    # Dedicated AI chat page
├── templates/fragments/
│   └── ai-chat-widget.html          # Reusable chat widget fragment for pet detail
└── static/js/
    └── ai-chat.js                   # SockJS/STOMP client, chat rendering, markdown

demos/petclinic/src/test/kotlin/cool/cfapps/petclinic/ai/
├── VetKnowledgeServiceTest.kt       # FTS retrieval tests
├── AiSettingsControllerTest.kt      # Settings CRUD tests
└── AiChatControllerTest.kt          # WebSocket + chat flow tests
```

### Modified Files

```
demos/petclinic/build.gradle.kts                          # Add Spring AI + WebSocket deps
demos/petclinic/src/main/resources/application.yml         # Spring AI config defaults
demos/petclinic/src/test/resources/application-test.yml    # Disable Spring AI auto-config in tests
demos/petclinic/src/main/kotlin/.../config/GlobalModelAttributes.kt  # Add aiEnabled, aiModel
demos/petclinic/src/main/resources/templates/fragments/navbar.html   # AI toggle + menu items
demos/petclinic/src/main/resources/templates/pets/detail.html        # AI chat widget
demos/petclinic/src/main/resources/static/css/petclinic.css          # AI chat styles
demos/petclinic/deploy-cf.sh                               # CF context switching (demo/spring)
```

---

### Task 1: Build Configuration — Spring AI + WebSocket Dependencies

**Files:**
- Modify: `demos/petclinic/build.gradle.kts`
- Modify: `demos/petclinic/src/main/resources/application.yml`
- Modify: `demos/petclinic/src/test/resources/application-test.yml`

- [ ] **Step 1: Add Spring AI milestone repository and dependencies to build.gradle.kts**

Add to `repositories` block:
```kotlin
maven { url = uri("https://repo.spring.io/milestone") }
```

Add to `dependencies` block:
```kotlin
val springAiVersion = "2.0.0-M3"
implementation("org.springframework.ai:spring-ai-ollama-spring-boot-starter:$springAiVersion")
implementation("org.springframework.boot:spring-boot-starter-websocket")
```

- [ ] **Step 2: Exclude Spring AI auto-configuration in application.yml**

Since `OllamaChatService` constructs the `OllamaChatModel` manually (dynamic URL from DB), we must prevent Spring Boot from auto-configuring one at startup (which would fail if Ollama is unreachable). Add to `application.yml` under `spring:`:
```yaml
spring:
  autoconfigure:
    exclude:
      - org.springframework.ai.autoconfigure.ollama.OllamaAutoConfiguration
```

Do NOT add `spring.ai.ollama` properties — the service handles URL/model dynamically.

- [ ] **Step 3: Disable Spring AI auto-config in test profile**

Add to `application-test.yml`:
```yaml
spring:
  autoconfigure:
    exclude:
      - org.springframework.ai.autoconfigure.ollama.OllamaAutoConfiguration
```

- [ ] **Step 4: Verify build compiles**

Run: `cd demos/petclinic && ./gradlew compileKotlin`
Expected: BUILD SUCCESSFUL

- [ ] **Step 5: Commit**

```bash
git add demos/petclinic/build.gradle.kts demos/petclinic/src/main/resources/application.yml demos/petclinic/src/test/resources/application-test.yml
git commit -m "feat(petclinic): add Spring AI and WebSocket dependencies"
```

---

### Task 2: Flyway Migration — ai_settings Table

**Files:**
- Create: `demos/petclinic/src/main/resources/db/migration/V3__ai_settings.sql`
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiSettings.kt`
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiSettingsRepository.kt`

- [ ] **Step 1: Create V3 migration**

Create `V3__ai_settings.sql`:
```sql
CREATE TABLE ai_settings (
    id         BIGINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled    BOOLEAN NOT NULL DEFAULT FALSE,
    ollama_url VARCHAR(500) DEFAULT 'http://192.168.64.1:11434',
    model_name VARCHAR(200) DEFAULT 'llama3.1:8b',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO ai_settings (id, enabled) VALUES (1, FALSE);
```

- [ ] **Step 2: Create AiSettings entity**

Create `AiSettings.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "ai_settings")
class AiSettings(
    @Id
    var id: Long = 1,

    @Column(name = "enabled")
    var enabled: Boolean = false,

    @Column(name = "ollama_url")
    var ollamaUrl: String = "http://192.168.64.1:11434",

    @Column(name = "model_name")
    var modelName: String = "llama3.1:8b",

    @Column(name = "updated_at")
    var updatedAt: LocalDateTime = LocalDateTime.now()
)
```

- [ ] **Step 3: Create AiSettingsRepository**

Create `AiSettingsRepository.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface AiSettingsRepository : JpaRepository<AiSettings, Long>

fun AiSettingsRepository.getSettings(): AiSettings =
    findById(1).orElseGet { save(AiSettings()) }
```

Note: Uses a Kotlin extension function instead of a default method in the interface, which avoids Spring Data JPA proxy compatibility issues.

- [ ] **Step 4: Verify tests still pass**

Run: `cd demos/petclinic && ./gradlew test`
Expected: Tests pass (H2 runs the V3 migration)

- [ ] **Step 5: Commit**

```bash
git add demos/petclinic/src/main/resources/db/migration/V3__ai_settings.sql demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/
git commit -m "feat(petclinic): add ai_settings table and JPA entity"
```

---

### Task 3: Flyway Migration — vet_knowledge Table + H2 Migration Path

**Files:**
- Create: `demos/petclinic/src/main/resources/db/migration/V4__vet_knowledge.sql`
- Create: `demos/petclinic/src/main/resources/db/migration-h2/V1__create_schema.sql` (copy of V1)
- Create: `demos/petclinic/src/main/resources/db/migration-h2/V2__seed_data.sql` (copy of V2)
- Create: `demos/petclinic/src/main/resources/db/migration-h2/V3__ai_settings.sql` (copy of V3)
- Create: `demos/petclinic/src/main/resources/db/migration-h2/V4__vet_knowledge.sql` (H2-compatible)
- Modify: `demos/petclinic/src/main/resources/application.yml` (add flyway location)
- Modify: `demos/petclinic/src/test/resources/application-test.yml` (H2 flyway location)
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/VetKnowledge.kt`
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/VetKnowledgeRepository.kt`

- [ ] **Step 1: Create H2 migration directory with copies of V1-V3**

H2 does not support `TSVECTOR` or `GENERATED ALWAYS AS` with `to_tsvector`. We need a separate migration path for H2 (tests + fallback).

```bash
mkdir -p demos/petclinic/src/main/resources/db/migration-h2
cp demos/petclinic/src/main/resources/db/migration/V1__create_schema.sql demos/petclinic/src/main/resources/db/migration-h2/
cp demos/petclinic/src/main/resources/db/migration/V2__seed_data.sql demos/petclinic/src/main/resources/db/migration-h2/
cp demos/petclinic/src/main/resources/db/migration/V3__ai_settings.sql demos/petclinic/src/main/resources/db/migration-h2/
```

- [ ] **Step 2: Configure Flyway locations per profile**

In `application.yml`, ensure (already present but make explicit):
```yaml
spring:
  flyway:
    locations: classpath:db/migration
```

In `application-test.yml`, add:
```yaml
spring:
  flyway:
    locations: classpath:db/migration-h2
```

Also add the same to `application-h2.yml`:
```yaml
spring:
  flyway:
    locations: classpath:db/migration-h2
```

- [ ] **Step 3: Create V4 PostgreSQL migration with table, indexes, and ~60 seed articles**

Create `V4__vet_knowledge.sql` with:
- Table definition with `search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', title || ' ' || content)) STORED`
- GIN index on `search_vector`
- Indexes on `category` and `pet_type`
- ~60 INSERT statements across 6 categories and 8 pet types

Seed data categories and example articles (each 200-400 words):
- **general_health** (~12): "Common Health Issues in Dogs", "Cat Wellness Guide", "Hamster Health Basics", etc.
- **nutrition** (~12): "Dog Nutrition by Life Stage", "Toxic Foods for Cats", "Rabbit Diet Essentials", etc.
- **vaccination** (~8): "Core Vaccines for Dogs", "Cat Vaccination Schedule", "Rabbit Vaccination Guide", etc.
- **emergency** (~10): "Dog Chocolate Poisoning", "Cat Emergency Signs", "Bird Emergency First Aid", etc.
- **post_visit** (~8): "Post-Surgery Dog Care", "Dental Cleaning Aftercare", "Post-Vaccination Care", etc.
- **senior_care** (~10): "Senior Dog Joint Health", "Aging Cat Care Guide", "Senior Rabbit Care", etc.

- [ ] **Step 4: Create H2-compatible V4 migration**

Create `db/migration-h2/V4__vet_knowledge.sql`:
```sql
CREATE TABLE vet_knowledge (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    category      VARCHAR(100) NOT NULL,
    pet_type      VARCHAR(50),
    title         VARCHAR(300) NOT NULL,
    content       CLOB NOT NULL,
    search_vector VARCHAR(1) DEFAULT NULL
);
```

Copy the same INSERT statements from the PostgreSQL version (omit `search_vector` column — it defaults to NULL in H2).

- [ ] **Step 2: Create VetKnowledge entity**

Create `VetKnowledge.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import jakarta.persistence.*

@Entity
@Table(name = "vet_knowledge")
class VetKnowledge(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @Column(name = "category")
    var category: String = "",

    @Column(name = "pet_type")
    var petType: String? = null,

    @Column(name = "title")
    var title: String = "",

    @Column(name = "content", columnDefinition = "TEXT")
    var content: String = ""
)
```

- [ ] **Step 3: Create VetKnowledgeRepository with native FTS query**

Create `VetKnowledgeRepository.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import org.springframework.stereotype.Repository

@Repository
interface VetKnowledgeRepository : JpaRepository<VetKnowledge, Long> {

    @Query(
        value = """
            SELECT vk.* FROM vet_knowledge vk,
                   to_tsquery('english', :queryTerms) query
            WHERE vk.search_vector @@ query
              AND (vk.pet_type IS NULL OR LOWER(vk.pet_type) = LOWER(:petType))
            ORDER BY ts_rank(vk.search_vector, query) DESC
            LIMIT :limit
        """,
        nativeQuery = true
    )
    fun searchByFts(
        @Param("queryTerms") queryTerms: String,
        @Param("petType") petType: String,
        @Param("limit") limit: Int = 3
    ): List<VetKnowledge>

    fun findByCategory(category: String): List<VetKnowledge>

    fun findByPetTypeIgnoreCase(petType: String): List<VetKnowledge>
}
```

- [ ] **Step 4: Verify tests pass with H2 migration path**

Run: `cd demos/petclinic && ./gradlew test`
Expected: Tests pass using H2 migration path

- [ ] **Step 5: Commit**

```bash
git add demos/petclinic/src/main/resources/db/ demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/VetKnowledge.kt demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/VetKnowledgeRepository.kt
git commit -m "feat(petclinic): add vet_knowledge table with FTS and seed data"
```

---

### Task 4: Flyway Migration — ai_chat_messages Table

**Files:**
- Create: `demos/petclinic/src/main/resources/db/migration/V5__ai_chat_messages.sql`
- Create: `demos/petclinic/src/main/resources/db/migration-h2/V5__ai_chat_messages.sql`
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiChatMessage.kt`
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiChatMessageRepository.kt`

- [ ] **Step 1: Create V5 migration (PostgreSQL)**

Create `V5__ai_chat_messages.sql`:
```sql
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
```

- [ ] **Step 2: Create H2-compatible V5 migration**

Create `db/migration-h2/V5__ai_chat_messages.sql`:
```sql
CREATE TABLE ai_chat_messages (
    id             BIGINT AUTO_INCREMENT PRIMARY KEY,
    pet_id         BIGINT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    session_id     VARCHAR(100) NOT NULL,
    role           VARCHAR(20) NOT NULL,
    content        CLOB NOT NULL,
    knowledge_refs CLOB,
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_chat_pet_id ON ai_chat_messages (pet_id);
CREATE INDEX idx_chat_session ON ai_chat_messages (session_id);
CREATE INDEX idx_chat_created ON ai_chat_messages (created_at DESC);
```

- [ ] **Step 3: Create AiChatMessage entity**

Create `AiChatMessage.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import cool.cfapps.petclinic.pet.Pet
import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "ai_chat_messages")
class AiChatMessage(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "pet_id")
    var pet: Pet = Pet(),

    @Column(name = "session_id")
    var sessionId: String = "",

    @Column(name = "role")
    var role: String = "",

    @Column(name = "content", columnDefinition = "TEXT")
    var content: String = "",

    @Column(name = "knowledge_refs", columnDefinition = "TEXT")
    var knowledgeRefs: String? = null,

    @Column(name = "created_at")
    var createdAt: LocalDateTime = LocalDateTime.now()
)
```

- [ ] **Step 4: Create AiChatMessageRepository**

Create `AiChatMessageRepository.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface AiChatMessageRepository : JpaRepository<AiChatMessage, Long> {
    fun findByPetIdOrderByCreatedAtAsc(petId: Long): List<AiChatMessage>
    fun findBySessionIdOrderByCreatedAtAsc(sessionId: String): List<AiChatMessage>
    fun findByPetIdAndSessionIdOrderByCreatedAtAsc(petId: Long, sessionId: String): List<AiChatMessage>
}
```

- [ ] **Step 5: Verify tests pass**

Run: `cd demos/petclinic && ./gradlew test`
Expected: Tests pass

- [ ] **Step 6: Commit**

```bash
git add demos/petclinic/src/main/resources/db/ demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiChatMessage.kt demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiChatMessageRepository.kt
git commit -m "feat(petclinic): add ai_chat_messages table for persistent pet chats"
```

---

### Task 5: VetKnowledgeService — FTS Retrieval + Prompt Building

**Files:**
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/VetKnowledgeService.kt`
- Create: `demos/petclinic/src/test/kotlin/cool/cfapps/petclinic/ai/VetKnowledgeServiceTest.kt`

- [ ] **Step 1: Write the test for search term extraction**

Create `VetKnowledgeServiceTest.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.*
import org.mockito.Mockito

class VetKnowledgeServiceTest {

    private val mockRepository = Mockito.mock(VetKnowledgeRepository::class.java)
    private val service = VetKnowledgeService(mockRepository)

    @Test
    fun `extractSearchTerms removes stop words and joins with ampersand`() {
        val result = service.extractSearchTerms("What should I feed my senior cat?")
        assertEquals("feed & senior & cat", result)
    }

    @Test
    fun `extractSearchTerms handles single word`() {
        val result = service.extractSearchTerms("vaccination")
        assertEquals("vaccination", result)
    }

    @Test
    fun `extractSearchTerms handles empty input`() {
        val result = service.extractSearchTerms("")
        assertEquals("", result)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd demos/petclinic && ./gradlew test --tests "cool.cfapps.petclinic.ai.VetKnowledgeServiceTest"`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement VetKnowledgeService**

Create `VetKnowledgeService.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import cool.cfapps.petclinic.pet.Pet
import cool.cfapps.petclinic.visit.Visit
import org.springframework.stereotype.Service

@Service
class VetKnowledgeService(
    private val repository: VetKnowledgeRepository
) {
    private val stopWords = setOf(
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "can", "shall", "to", "of", "in", "for",
        "on", "with", "at", "by", "from", "as", "into", "about", "like",
        "through", "after", "over", "between", "out", "against", "during",
        "without", "before", "under", "around", "among", "i", "me", "my",
        "we", "our", "you", "your", "he", "she", "it", "they", "them",
        "what", "which", "who", "when", "where", "why", "how", "not", "no",
        "and", "but", "or", "if", "then", "so", "than", "too", "very",
        "just", "don", "t", "s"
    )

    fun extractSearchTerms(question: String): String {
        if (question.isBlank()) return ""
        return question.lowercase()
            .replace(Regex("[^a-z0-9\\s]"), "")
            .split("\\s+".toRegex())
            .filter { it.isNotBlank() && it !in stopWords && it.length > 1 }
            .distinct()
            .joinToString(" & ")
    }

    fun searchKnowledge(question: String, petType: String? = null, limit: Int = 3): List<VetKnowledge> {
        val terms = extractSearchTerms(question)
        if (terms.isBlank()) return emptyList()
        return try {
            repository.searchByFts(terms, petType ?: "", limit)
        } catch (e: Exception) {
            // FTS not available (H2) — return empty
            emptyList()
        }
    }

    fun buildContext(articles: List<VetKnowledge>, pet: Pet? = null, visits: List<Visit>? = null): String {
        val sb = StringBuilder()

        if (pet != null) {
            sb.appendLine("## Pet Information")
            sb.appendLine("Name: ${pet.name}")
            sb.appendLine("Type: ${pet.type.name}")
            sb.appendLine("Birth Date: ${pet.birthDate}")
            sb.appendLine("Owner: ${pet.owner.firstName} ${pet.owner.lastName}")
            if (!visits.isNullOrEmpty()) {
                sb.appendLine("Recent visits:")
                visits.takeLast(5).forEach { visit ->
                    sb.appendLine("- ${visit.date}: ${visit.description} (${visit.status}, Dr. ${visit.vet.lastName})")
                }
            }
            sb.appendLine()
        }

        if (articles.isNotEmpty()) {
            sb.appendLine("## Veterinary Knowledge Base")
            articles.forEach { article ->
                sb.appendLine("### ${article.title}")
                sb.appendLine(article.content)
                sb.appendLine()
            }
        }

        return sb.toString()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd demos/petclinic && ./gradlew test --tests "cool.cfapps.petclinic.ai.VetKnowledgeServiceTest"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/VetKnowledgeService.kt demos/petclinic/src/test/kotlin/cool/cfapps/petclinic/ai/VetKnowledgeServiceTest.kt
git commit -m "feat(petclinic): add VetKnowledgeService with FTS retrieval and prompt building"
```

---

### Task 6: OllamaChatService — Dynamic Spring AI ChatClient

**Files:**
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/OllamaChatService.kt`

- [ ] **Step 1: Create OllamaChatService**

Create `OllamaChatService.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import org.springframework.ai.chat.client.ChatClient
import org.springframework.ai.chat.prompt.Prompt
import org.springframework.ai.ollama.OllamaChatModel
import org.springframework.ai.ollama.api.OllamaApi
import org.springframework.ai.ollama.api.OllamaOptions
import org.springframework.stereotype.Service
import reactor.core.publisher.Flux
import java.util.concurrent.atomic.AtomicReference

@Service
class OllamaChatService(
    private val settingsRepository: AiSettingsRepository
) {
    private val chatClientRef = AtomicReference<ChatClient?>(null)
    private val lastUrl = AtomicReference<String?>(null)
    private val lastModel = AtomicReference<String?>(null)

    companion object {
        const val SYSTEM_PROMPT = """You are a friendly and knowledgeable veterinary AI assistant for a pet clinic.
Your role is to provide helpful information about pet health, nutrition, vaccinations, and general care.

IMPORTANT RULES:
1. Always include a disclaimer that you are not a substitute for professional veterinary care.
2. For emergencies, always recommend contacting a veterinarian immediately.
3. Base your answers on the provided knowledge base context when available.
4. If no knowledge base context is provided, answer from your general knowledge but note this.
5. Be empathetic and supportive in your responses.
6. Keep responses concise but informative.
7. When discussing a specific pet, reference their details (name, age, type) naturally."""
    }

    fun getChatClient(): ChatClient {
        val settings = settingsRepository.getSettings()
        val url = settings.ollamaUrl
        val model = settings.modelName

        // Rebuild if settings changed
        if (url != lastUrl.get() || model != lastModel.get()) {
            val ollamaApi = OllamaApi(url)
            val chatModel = OllamaChatModel.builder()
                .ollamaApi(ollamaApi)
                .defaultOptions(OllamaOptions.builder().model(model).build())
                .build()
            val client = ChatClient.builder(chatModel)
                .defaultSystem(SYSTEM_PROMPT)
                .build()
            chatClientRef.set(client)
            lastUrl.set(url)
            lastModel.set(model)
        }
        return chatClientRef.get() ?: throw IllegalStateException("ChatClient not initialized")
    }

    fun streamChat(userMessage: String, context: String): Flux<String> {
        val client = getChatClient()
        val fullPrompt = if (context.isNotBlank()) {
            """Here is relevant context for answering the question:

$context

User question: $userMessage"""
        } else {
            userMessage
        }

        return client.prompt()
            .user(fullPrompt)
            .stream()
            .content()
    }

    fun isAvailable(): Boolean {
        return try {
            val settings = settingsRepository.getSettings()
            if (!settings.enabled) return false
            val url = settings.ollamaUrl
            // Simple connectivity check
            val connection = java.net.URI(url).toURL().openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = 3000
            connection.readTimeout = 3000
            connection.requestMethod = "GET"
            connection.responseCode == 200
        } catch (e: Exception) {
            false
        }
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd demos/petclinic && ./gradlew compileKotlin`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Commit**

```bash
git add demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/OllamaChatService.kt
git commit -m "feat(petclinic): add OllamaChatService with dynamic ChatClient"
```

---

### Task 7: WebSocket Configuration

**Files:**
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/WebSocketConfig.kt`

- [ ] **Step 1: Create WebSocket STOMP configuration**

Create `WebSocketConfig.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import org.springframework.context.annotation.Configuration
import org.springframework.messaging.simp.config.MessageBrokerRegistry
import org.springframework.web.socket.config.annotation.EnableWebSocketMessageBroker
import org.springframework.web.socket.config.annotation.StompEndpointRegistry
import org.springframework.web.socket.config.annotation.WebSocketMessageBrokerConfigurer

@Configuration
@EnableWebSocketMessageBroker
class WebSocketConfig : WebSocketMessageBrokerConfigurer {

    override fun configureMessageBroker(config: MessageBrokerRegistry) {
        config.enableSimpleBroker("/topic")
        config.setApplicationDestinationPrefixes("/app")
    }

    override fun registerStompEndpoints(registry: StompEndpointRegistry) {
        registry.addEndpoint("/ws").setAllowedOriginPatterns("*").withSockJS()
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd demos/petclinic && ./gradlew compileKotlin`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Commit**

```bash
git add demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/WebSocketConfig.kt
git commit -m "feat(petclinic): add STOMP/SockJS WebSocket configuration"
```

---

### Task 8: AiSettingsController — Settings Page

**Files:**
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiSettingsController.kt`
- Create: `demos/petclinic/src/main/resources/templates/ai/settings.html`
- Modify: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/config/GlobalModelAttributes.kt`

- [ ] **Step 1: Create AiSettingsController**

Create `AiSettingsController.kt` with:
- `GET /ai/settings` — render settings page with current config from DB
- `POST /ai/settings` — save settings (ollama URL, model, enabled), update `updated_at`
- `GET /ai/settings/models` — REST endpoint that proxies `GET {ollamaUrl}/api/tags` and returns model names as JSON
- `GET /ai/settings/test` — REST endpoint that tests Ollama connectivity, returns status JSON

```kotlin
package cool.cfapps.petclinic.ai

import org.springframework.http.ResponseEntity
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*
import org.springframework.web.client.RestClient
import java.time.LocalDateTime

@Controller
@RequestMapping("/ai")
class AiSettingsController(
    private val settingsRepository: AiSettingsRepository
) {

    @GetMapping("/settings")
    fun settingsPage(model: Model): String {
        model.addAttribute("settings", settingsRepository.getSettings())
        return "ai/settings"
    }

    @PostMapping("/settings")
    fun saveSettings(
        @RequestParam ollamaUrl: String,
        @RequestParam modelName: String,
        @RequestParam(required = false) enabled: Boolean?
    ): String {
        val settings = settingsRepository.getSettings()
        settings.ollamaUrl = ollamaUrl.trimEnd('/')
        settings.modelName = modelName
        settings.enabled = enabled ?: false
        settings.updatedAt = LocalDateTime.now()
        settingsRepository.save(settings)
        return "redirect:/ai/settings"
    }

    @GetMapping("/settings/models")
    @ResponseBody
    fun listModels(): ResponseEntity<Any> {
        val settings = settingsRepository.getSettings()
        return try {
            val response = RestClient.create()
                .get()
                .uri("${settings.ollamaUrl}/api/tags")
                .retrieve()
                .body(Map::class.java)
            ResponseEntity.ok(response)
        } catch (e: Exception) {
            ResponseEntity.status(503).body(mapOf("error" to (e.message ?: "Connection failed")))
        }
    }

    @GetMapping("/settings/test")
    @ResponseBody
    fun testConnection(): ResponseEntity<Map<String, Any>> {
        val settings = settingsRepository.getSettings()
        return try {
            val response = RestClient.create()
                .get()
                .uri("${settings.ollamaUrl}/api/tags")
                .retrieve()
                .body(Map::class.java)
            val models = (response?.get("models") as? List<*>)?.size ?: 0
            ResponseEntity.ok(mapOf(
                "status" to "connected",
                "url" to settings.ollamaUrl,
                "models" to models
            ))
        } catch (e: Exception) {
            ResponseEntity.ok(mapOf(
                "status" to "error",
                "message" to (e.message ?: "Connection failed")
            ))
        }
    }

    @PostMapping("/toggle")
    @ResponseBody
    fun toggleAi(): ResponseEntity<Map<String, Any>> {
        val settings = settingsRepository.getSettings()
        if (settings.ollamaUrl.isBlank()) {
            return ResponseEntity.ok(mapOf("redirect" to "/ai/settings"))
        }
        settings.enabled = !settings.enabled
        settings.updatedAt = LocalDateTime.now()
        settingsRepository.save(settings)
        return ResponseEntity.ok(mapOf("enabled" to settings.enabled))
    }
}
```

- [ ] **Step 2: Create settings.html template**

Create `demos/petclinic/src/main/resources/templates/ai/settings.html` — a Thymeleaf page following the existing dark-theme style with:
- Form with Ollama URL input (pre-filled from DB, default `http://192.168.64.1:11434`)
- Model select dropdown (populated via JS fetch to `/ai/settings/models`)
- Enable/disable radio buttons
- "Test Connection" button with JavaScript that calls `/ai/settings/test` and shows result
- "Save" button that submits the form
- Status indicator showing connection state

Follow the existing page structure: navbar fragment, container, card-based form, layout footer, Bootstrap 5.3.3.

- [ ] **Step 3: Extend GlobalModelAttributes to expose AI state**

Modify `GlobalModelAttributes.kt` — add `AiSettingsRepository` dependency and expose `aiEnabled` and `aiModel`:

```kotlin
@ControllerAdvice
class GlobalModelAttributes(
    private val databaseInfoContributor: DatabaseInfoContributor,
    private val petclinicProperties: PetclinicProperties,
    private val aiSettingsRepository: AiSettingsRepository
) {
    // ... existing code ...

    @ModelAttribute
    fun addGlobalAttributes(model: Model) {
        // ... existing attributes ...
        val aiSettings = aiSettingsRepository.getSettings()
        model.addAttribute("aiEnabled", aiSettings.enabled)
        model.addAttribute("aiModel", aiSettings.modelName)
        model.addAttribute("aiOllamaUrl", aiSettings.ollamaUrl)
    }
}
```

- [ ] **Step 4: Verify build compiles and tests pass**

Run: `cd demos/petclinic && ./gradlew test`
Expected: Tests pass

- [ ] **Step 5: Commit**

```bash
git add demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiSettingsController.kt demos/petclinic/src/main/resources/templates/ai/settings.html demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/config/GlobalModelAttributes.kt
git commit -m "feat(petclinic): add AI settings page with Ollama connection management"
```

---

### Task 9: Navbar AI Toggle + Menu Items

**Files:**
- Modify: `demos/petclinic/src/main/resources/templates/fragments/navbar.html`
- Modify: `demos/petclinic/src/main/resources/static/css/petclinic.css`

- [ ] **Step 1: Add AI toggle and conditional menu items to navbar**

Modify `navbar.html` to add after the Appointments nav-item:

```html
<!-- AI Toggle Button (always visible) -->
<li class="nav-item">
    <a class="nav-link ai-toggle" href="#" th:attr="data-enabled=${aiEnabled}"
       onclick="toggleAi(event)">
        <i class="bi bi-stars me-1"></i>AI
        <span class="ai-status-badge" th:classappend="${aiEnabled} ? 'ai-on' : 'ai-off'"
              th:text="${aiEnabled} ? 'ON' : 'OFF'">OFF</span>
    </a>
</li>

<!-- AI Menu Items (visible only when AI enabled) -->
<li class="nav-item" th:if="${aiEnabled}">
    <a class="nav-link" th:classappend="${activeMenu == 'ai-chat'} ? 'active'"
       th:href="@{/ai/chat}">
        <i class="bi bi-chat-dots me-1"></i>AI Chat
    </a>
</li>
<li class="nav-item" th:if="${aiEnabled}">
    <a class="nav-link" th:classappend="${activeMenu == 'ai-settings'} ? 'active'"
       th:href="@{/ai/settings}">
        <i class="bi bi-gear me-1"></i>AI Settings
    </a>
</li>
```

Add model badge to the right side badges area (before runtime badge):
```html
<!-- AI Model badge (when enabled) -->
<span class="ai-model-badge" th:if="${aiEnabled}">
    <i class="bi bi-robot me-1"></i>
    <span th:text="${aiModel}">llama3.1:8b</span>
</span>
```

Add JavaScript for the toggle button (inline or in a script block):
```javascript
function toggleAi(event) {
    event.preventDefault();
    fetch('/ai/toggle', { method: 'POST' })
        .then(r => r.json())
        .then(data => {
            if (data.redirect) { window.location.href = data.redirect; }
            else { window.location.reload(); }
        });
}
```

- [ ] **Step 2: Add AI CSS styles to petclinic.css**

Append to `petclinic.css`:
```css
/* AI Toggle */
.ai-status-badge { font-size: 0.65rem; padding: 1px 6px; border-radius: 8px; margin-left: 4px; }
.ai-status-badge.ai-on { background: var(--spring-green); color: #fff; }
.ai-status-badge.ai-off { background: #555; color: #999; }
.ai-model-badge { background: rgba(255, 152, 0, 0.15); padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; color: #ff9800; }
.ai-toggle:hover .ai-status-badge { opacity: 0.8; }
```

- [ ] **Step 3: Verify the page renders (manual check or build)**

Run: `cd demos/petclinic && ./gradlew compileKotlin`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Commit**

```bash
git add demos/petclinic/src/main/resources/templates/fragments/navbar.html demos/petclinic/src/main/resources/static/css/petclinic.css
git commit -m "feat(petclinic): add AI toggle button and conditional menu items in navbar"
```

---

### Task 10: AiChatController — STOMP Message Handler

**Files:**
- Create: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiChatController.kt`

- [ ] **Step 1: Create AiChatController with STOMP handler**

Create `AiChatController.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import com.fasterxml.jackson.databind.ObjectMapper
import cool.cfapps.petclinic.pet.PetRepository
import cool.cfapps.petclinic.visit.VisitRepository
import org.springframework.messaging.handler.annotation.MessageMapping
import org.springframework.messaging.handler.annotation.Payload
import org.springframework.messaging.simp.SimpMessagingTemplate
import org.springframework.stereotype.Controller
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.ResponseBody

data class ChatMessage(
    val content: String = "",
    val sessionId: String = "",
    val petId: Long? = null
)

data class ChatResponse(
    val type: String,  // "token", "done", "error", "sources"
    val content: String = "",
    val sessionId: String = ""
)

@Controller
class AiChatController(
    private val messagingTemplate: SimpMessagingTemplate,
    private val ollamaChatService: OllamaChatService,
    private val vetKnowledgeService: VetKnowledgeService,
    private val chatMessageRepository: AiChatMessageRepository,
    private val petRepository: PetRepository,
    private val visitRepository: VisitRepository,
    private val objectMapper: ObjectMapper
) {

    @MessageMapping("/chat.send")
    fun handleChatMessage(@Payload message: ChatMessage) {
        val destination = "/topic/chat.${message.sessionId}"
        val responseBuilder = StringBuilder()

        try {
            // Load pet context if pet chat
            val pet = message.petId?.let { petRepository.findById(it).orElse(null) }
            val visits = message.petId?.let { visitRepository.findByPetId(it) }
            val petType = pet?.type?.name

            // FTS retrieval
            val articles = vetKnowledgeService.searchKnowledge(message.content, petType)
            val context = vetKnowledgeService.buildContext(articles, pet, visits)

            // Send source references
            if (articles.isNotEmpty()) {
                val sources = articles.map { it.title }
                messagingTemplate.convertAndSend(destination, ChatResponse(
                    type = "sources",
                    content = objectMapper.writeValueAsString(sources),
                    sessionId = message.sessionId
                ))
            }

            // Stream from Ollama
            ollamaChatService.streamChat(message.content, context)
                .doOnNext { token ->
                    responseBuilder.append(token)
                    messagingTemplate.convertAndSend(destination, ChatResponse(
                        type = "token",
                        content = token,
                        sessionId = message.sessionId
                    ))
                }
                .doOnComplete {
                    messagingTemplate.convertAndSend(destination, ChatResponse(
                        type = "done",
                        sessionId = message.sessionId
                    ))
                    // Persist pet chat messages
                    if (message.petId != null && pet != null) {
                        val refs = if (articles.isNotEmpty())
                            objectMapper.writeValueAsString(articles.map { it.title })
                        else null
                        chatMessageRepository.save(AiChatMessage(
                            pet = pet,
                            sessionId = message.sessionId,
                            role = "user",
                            content = message.content
                        ))
                        chatMessageRepository.save(AiChatMessage(
                            pet = pet,
                            sessionId = message.sessionId,
                            role = "assistant",
                            content = responseBuilder.toString(),
                            knowledgeRefs = refs
                        ))
                    }
                }
                .doOnError { error ->
                    messagingTemplate.convertAndSend(destination, ChatResponse(
                        type = "error",
                        content = error.message ?: "An error occurred",
                        sessionId = message.sessionId
                    ))
                }
                .subscribe()

        } catch (e: Exception) {
            messagingTemplate.convertAndSend(destination, ChatResponse(
                type = "error",
                content = e.message ?: "Failed to process message",
                sessionId = message.sessionId
            ))
        }
    }

    @GetMapping("/ai/chat/history/{petId}")
    @ResponseBody
    fun getChatHistory(@PathVariable petId: Long): List<Map<String, Any?>> {
        return chatMessageRepository.findByPetIdOrderByCreatedAtAsc(petId).map {
            mapOf(
                "role" to it.role,
                "content" to it.content,
                "sessionId" to it.sessionId,
                "knowledgeRefs" to it.knowledgeRefs,
                "createdAt" to it.createdAt.toString()
            )
        }
    }

    @GetMapping("/ai/chat/sessions/{petId}")
    @ResponseBody
    fun getChatSessions(@PathVariable petId: Long): List<Map<String, String>> {
        val messages = chatMessageRepository.findByPetIdOrderByCreatedAtAsc(petId)
        return messages.groupBy { it.sessionId }.map { (sessionId, msgs) ->
            mapOf(
                "sessionId" to sessionId,
                "firstMessage" to (msgs.firstOrNull { it.role == "user" }?.content?.take(50) ?: ""),
                "date" to (msgs.first().createdAt.toLocalDate().toString())
            )
        }
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd demos/petclinic && ./gradlew compileKotlin`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Commit**

```bash
git add demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiChatController.kt
git commit -m "feat(petclinic): add STOMP chat controller with RAG retrieval and streaming"
```

---

### Task 11: AI Chat JavaScript Client

**Files:**
- Create: `demos/petclinic/src/main/resources/static/js/ai-chat.js`

- [ ] **Step 1: Create SockJS/STOMP client with message rendering**

Create `ai-chat.js` with:
- SockJS connection to `/ws`
- STOMP subscribe to `/topic/chat.{sessionId}`
- `sendMessage(content, petId)` function
- Token-by-token rendering in chat container
- Source attribution display
- Error handling and reconnection
- Connection status indicator
- Cancel/stop generation support
- Session ID management (UUID generation, pet session lookup)
- Markdown rendering (basic: bold, italic, lists, line breaks)
- Auto-scroll to latest message

Key structure:
```javascript
const AiChat = {
    stompClient: null,
    sessionId: null,
    connected: false,

    connect() { /* SockJS + STOMP connect */ },
    disconnect() { /* cleanup */ },
    subscribe() { /* listen on /topic/chat.{sessionId} */ },
    sendMessage(content, petId) { /* STOMP send to /app/chat.send */ },
    renderToken(token) { /* append to current response div */ },
    renderComplete() { /* finalize message, show sources */ },
    renderError(message) { /* show error in chat */ },
    generateSessionId() { return crypto.randomUUID(); },
    loadHistory(petId) { /* fetch /ai/chat/history/{petId} */ },
    loadSessions(petId) { /* fetch /ai/chat/sessions/{petId} */ }
};
```

Include SockJS and STOMP.js via CDN in templates that use this:
```html
<script src="https://cdn.jsdelivr.net/npm/sockjs-client@1/dist/sockjs.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@stomp/stompjs@7/bundles/stomp.umd.min.js"></script>
```

- [ ] **Step 2: Commit**

```bash
git add demos/petclinic/src/main/resources/static/js/ai-chat.js
git commit -m "feat(petclinic): add SockJS/STOMP AI chat JavaScript client"
```

---

### Task 12: Dedicated AI Chat Page

**Files:**
- Create: `demos/petclinic/src/main/resources/templates/ai/chat.html`
- Modify: `demos/petclinic/src/main/resources/static/css/petclinic.css`

- [ ] **Step 1: Create chat.html template**

Create `demos/petclinic/src/main/resources/templates/ai/chat.html` — full Thymeleaf page with:
- Navbar with `activeMenu='ai-chat'`
- Two-column layout: left sidebar (topic categories + quick questions), right chat area
- Topic categories: General Health, Nutrition & Diet, Vaccinations, Emergency Help, Post-Visit Care
- Quick question templates that populate the input field on click
- Chat message area with AI welcome message and disclaimer
- Message input with send button
- SockJS/STOMP script includes
- Initializes `AiChat.connect()` on page load

Add a simple controller method to serve the page — add to `AiSettingsController.kt` or create a minimal mapping:
```kotlin
@GetMapping("/chat")
fun chatPage(model: Model): String {
    return "ai/chat"
}
```

Follow the existing dark theme (Spring Green accents, Bootstrap 5.3.3 cards/tables).

- [ ] **Step 2: Add AI chat page CSS to petclinic.css**

Append chat-specific styles:
```css
/* AI Chat Page */
.ai-chat-container { display: flex; height: calc(100vh - 120px); }
.ai-chat-sidebar { width: 240px; border-right: 1px solid var(--spring-border); padding: 1rem; overflow-y: auto; }
.ai-chat-main { flex: 1; display: flex; flex-direction: column; }
.ai-chat-messages { flex: 1; overflow-y: auto; padding: 1rem; }
.ai-chat-input { padding: 0.8rem; border-top: 1px solid var(--spring-border); display: flex; gap: 0.5rem; }
.ai-message { display: flex; gap: 0.6rem; margin-bottom: 1rem; }
.ai-message-user { justify-content: flex-end; }
.ai-message-bubble { background: var(--spring-card); padding: 0.7rem 1rem; border-radius: 12px; max-width: 80%; }
.ai-message-user .ai-message-bubble { background: rgba(109, 179, 63, 0.15); }
.ai-avatar { width: 32px; height: 32px; border-radius: 50%; background: linear-gradient(135deg, #bb86fc, #6db33f); display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.ai-sources { font-size: 0.7rem; color: #bb86fc; border-top: 1px solid var(--spring-border); margin-top: 0.5rem; padding-top: 0.3rem; }
.ai-topic-btn { display: block; width: 100%; text-align: left; padding: 6px 10px; border-radius: 6px; border: none; background: transparent; color: #aaa; cursor: pointer; font-size: 0.85rem; }
.ai-topic-btn:hover, .ai-topic-btn.active { background: rgba(187, 134, 252, 0.15); color: #bb86fc; }
.ai-quick-question { padding: 6px 10px; border-radius: 6px; background: var(--spring-card); color: var(--spring-green); font-size: 0.75rem; cursor: pointer; border: 1px solid var(--spring-border); }
.ai-quick-question:hover { border-color: var(--spring-green); }
```

- [ ] **Step 3: Verify build and templates render**

Run: `cd demos/petclinic && ./gradlew compileKotlin`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Commit**

```bash
git add demos/petclinic/src/main/resources/templates/ai/chat.html demos/petclinic/src/main/resources/static/css/petclinic.css demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/ai/AiSettingsController.kt
git commit -m "feat(petclinic): add dedicated AI chat page with topic sidebar"
```

---

### Task 13: Pet Detail AI Chat Widget

**Files:**
- Create: `demos/petclinic/src/main/resources/templates/fragments/ai-chat-widget.html`
- Modify: `demos/petclinic/src/main/resources/templates/pets/detail.html`

- [ ] **Step 1: Create reusable AI chat widget fragment**

Create `ai-chat-widget.html` — Thymeleaf fragment that renders:
- "Ask AI about {petName}" toggle button
- Expandable chat panel with context banner (pet type, age, last visit, visit count)
- Compact chat message area
- Message input
- Previous sessions as clickable tags
- SockJS/STOMP initialization with pet context

Fragment signature: `th:fragment="chatWidget(pet, visits)"`

- [ ] **Step 2: Integrate widget into pet detail page**

Modify `demos/petclinic/src/main/resources/templates/pets/detail.html`:
- Add `th:if="${aiEnabled}"` block after the Visit History section
- Include the chat widget fragment: `th:replace="~{fragments/ai-chat-widget :: chatWidget(${pet}, ${visits})}"`
- Add SockJS + STOMP.js + ai-chat.js script includes (only when AI enabled)

- [ ] **Step 3: Add widget-specific CSS to petclinic.css**

```css
/* AI Pet Chat Widget */
.ai-pet-widget { border: 1px solid rgba(187, 134, 252, 0.3); border-radius: 12px; background: rgba(187, 134, 252, 0.03); overflow: hidden; margin-top: 1.5rem; }
.ai-pet-widget-header { padding: 0.6rem 1rem; background: rgba(187, 134, 252, 0.1); display: flex; align-items: center; justify-content: space-between; }
.ai-pet-context { padding: 0.4rem 1rem; background: rgba(109, 179, 63, 0.08); border-bottom: 1px solid var(--spring-border); font-size: 0.7rem; color: var(--spring-green); }
.ai-pet-sessions { padding: 0.6rem; background: var(--spring-bg); display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ai-pet-session-tag { background: var(--spring-card); padding: 4px 10px; border-radius: 6px; font-size: 0.7rem; color: #aaa; cursor: pointer; border: 1px solid var(--spring-border); }
.ai-pet-session-tag:hover { border-color: #bb86fc; color: #bb86fc; }
```

- [ ] **Step 4: Commit**

```bash
git add demos/petclinic/src/main/resources/templates/fragments/ai-chat-widget.html demos/petclinic/src/main/resources/templates/pets/detail.html demos/petclinic/src/main/resources/static/css/petclinic.css
git commit -m "feat(petclinic): add AI chat widget on pet detail page"
```

---

### Task 14: Visit Detail AI Tips

**Files:**
- Modify: `demos/petclinic/src/main/resources/templates/visits/` (if visit detail page exists, otherwise skip)
- Modify: `demos/petclinic/src/main/kotlin/cool/cfapps/petclinic/visit/VisitController.kt`

- [ ] **Step 1: Add AI tips section to visit form/detail pages**

When AI is enabled and a visit is displayed, add a contextual "AI Tips" card below the visit details. The tips button triggers a one-shot AI query based on the visit description (e.g., "post-dental-cleaning care") and displays the result inline.

Add to the visit detail/form template (conditional on `th:if="${aiEnabled}"`):
```html
<!-- AI Tips (when AI enabled) -->
<div th:if="${aiEnabled}" class="card mt-3">
    <div class="card-header" style="background: rgba(187, 134, 252, 0.1);">
        <i class="bi bi-stars me-2" style="color: #bb86fc;"></i>AI Tips
    </div>
    <div class="card-body" id="aiTipsContent">
        <button class="btn btn-sm btn-outline-secondary" onclick="loadAiTips()" id="aiTipsBtn">
            <i class="bi bi-lightbulb me-1"></i>Get AI advice for this visit
        </button>
        <div id="aiTipsResult" class="mt-2" style="display:none;"></div>
    </div>
</div>
```

Add inline JavaScript that sends the visit description + pet type to `/app/chat.send` via the existing WebSocket and renders the response into `#aiTipsResult`. Include SockJS/STOMP/ai-chat.js scripts conditionally.

- [ ] **Step 2: Add CSS for AI tips card**

Append to `petclinic.css`:
```css
/* AI Tips on visits */
.ai-tips-loading { color: #bb86fc; font-size: 0.85rem; }
.ai-tips-content { font-size: 0.85rem; color: #ccc; line-height: 1.6; }
```

- [ ] **Step 3: Commit**

```bash
git add demos/petclinic/src/main/resources/templates/ demos/petclinic/src/main/resources/static/css/petclinic.css
git commit -m "feat(petclinic): add AI tips section on visit detail pages"
```

---

### Task 15: Deploy Script — CF Context Switching

**Files:**
- Modify: `demos/petclinic/deploy-cf.sh`

- [ ] **Step 1: Add context switching to deploy-cf.sh**

Modify `deploy-cf.sh` to:
1. Save current org/space at the top
2. Add `trap` to restore on exit
3. Switch to `demo/spring` before deployment
4. Restore original context after deployment

Replace the section after "Check CF CLI is logged in" through the org/space echo:

```bash
# Save current CF context
PREV_ORG=$(cf target | grep "org:" | awk '{print $2}')
PREV_SPACE=$(cf target | grep "space:" | awk '{print $2}')
TARGET_ORG="demo"
TARGET_SPACE="spring"

# Restore context on exit (success or failure)
restore_context() {
    if [ -n "$PREV_ORG" ] && [ -n "$PREV_SPACE" ]; then
        echo ""
        echo "Restoring CF context: $PREV_ORG/$PREV_SPACE"
        cf target -o "$PREV_ORG" -s "$PREV_SPACE" >/dev/null 2>&1
    fi
}
trap restore_context EXIT

# Switch to target org/space
echo "Switching to: org=$TARGET_ORG space=$TARGET_SPACE (was: $PREV_ORG/$PREV_SPACE)"
cf target -o "$TARGET_ORG" -s "$TARGET_SPACE"
echo ""
```

Remove the old `ORG=` / `SPACE=` / echo lines.

- [ ] **Step 2: Verify script syntax**

Run: `bash -n demos/petclinic/deploy-cf.sh`
Expected: No syntax errors

- [ ] **Step 3: Commit**

```bash
git add demos/petclinic/deploy-cf.sh
git commit -m "feat(petclinic): add CF context switching (demo/spring) with auto-restore"
```

---

### Task 16: Integration Testing

**Files:**
- Create: `demos/petclinic/src/test/kotlin/cool/cfapps/petclinic/ai/AiSettingsControllerTest.kt`
- Modify: `demos/petclinic/src/test/kotlin/cool/cfapps/petclinic/PetclinicApplicationTests.kt`

- [ ] **Step 1: Write AiSettingsController integration test**

Create `AiSettingsControllerTest.kt`:
```kotlin
package cool.cfapps.petclinic.ai

import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.post

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class AiSettingsControllerTest {

    @Autowired
    lateinit var mockMvc: MockMvc

    @Autowired
    lateinit var settingsRepository: AiSettingsRepository

    @Test
    fun `GET ai settings returns settings page`() {
        mockMvc.get("/ai/settings").andExpect {
            status { isOk() }
            view { name("ai/settings") }
        }
    }

    @Test
    fun `POST ai settings saves and redirects`() {
        mockMvc.post("/ai/settings") {
            param("ollamaUrl", "http://localhost:11434")
            param("modelName", "llama3.1:8b")
            param("enabled", "true")
        }.andExpect {
            status { is3xxRedirection() }
            redirectedUrl("/ai/settings")
        }

        val saved = settingsRepository.getSettings()
        assert(saved.enabled)
        assert(saved.ollamaUrl == "http://localhost:11434")
        assert(saved.modelName == "llama3.1:8b")
    }

    @Test
    fun `POST toggle toggles enabled state`() {
        val before = settingsRepository.getSettings()
        val wasBefore = before.enabled

        mockMvc.post("/ai/toggle").andExpect {
            status { isOk() }
        }

        val after = settingsRepository.getSettings()
        assert(after.enabled != wasBefore)
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `cd demos/petclinic && ./gradlew test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add demos/petclinic/src/test/
git commit -m "test(petclinic): add AI settings integration tests"
```

---

### Task 17: Final Verification + Manual Smoke Test

- [ ] **Step 1: Run full build**

Run: `cd demos/petclinic && ./gradlew clean build`
Expected: BUILD SUCCESSFUL

- [ ] **Step 2: Start Ollama locally**

Run: `OLLAMA_HOST=0.0.0.0 ollama serve` (if not already running)
Verify model: `ollama list` should show `llama3.1:8b`

- [ ] **Step 3: Start app with local PostgreSQL**

Run: `cd demos/petclinic && docker compose up -d && ./gradlew bootRun`
Expected: App starts on port 8080, Flyway runs V3-V5 migrations

- [ ] **Step 4: Manual smoke test checklist**

1. Open http://localhost:8080 — navbar shows AI button with OFF badge
2. Click AI → redirected to /ai/settings
3. Enter Ollama URL (`http://localhost:11434`), select model, enable, save
4. Navbar now shows AI ON, AI Chat and AI Settings menu items, model badge
5. Navigate to /ai/chat — sidebar with topics visible, welcome message
6. Type "What should I feed a senior dog?" — response streams token by token via WebSocket
7. Response shows RAG source attribution
8. Navigate to /pets/{id} — "Ask AI about {petName}" button visible
9. Click button — chat widget expands with pet context banner
10. Ask "Is Buddy due for vaccinations?" — pet-aware response
11. Refresh page — previous conversation still visible
12. Click AI toggle OFF — all AI elements disappear

- [ ] **Step 5: Commit any fixes from smoke test**

```bash
git add -u demos/petclinic/
git commit -m "fix(petclinic): fixes from AI companion smoke test"
```

---

### Task 18: CF Deployment

- [ ] **Step 1: Build the JAR**

Run: `cd demos/petclinic && ./gradlew bootJar`
Expected: JAR created at `build/libs/petclinic-0.0.1-SNAPSHOT.jar`

- [ ] **Step 2: Deploy to CF**

Run: `cd demos/petclinic && ./deploy-cf.sh`
Expected: App deploys to `demo/spring`, context restored to `kappman/app`

- [ ] **Step 3: Verify deployment**

Open https://petclinic.app.cfapps.cool
- Navbar shows Cloud Foundry runtime badge
- AI button visible, configure with Ollama URL `http://192.168.64.1:11434`
- Chat functionality works through Korifi ingress

- [ ] **Step 4: Commit deployment state if manifest changed**

Only if manifest.yml needed updates during testing.
