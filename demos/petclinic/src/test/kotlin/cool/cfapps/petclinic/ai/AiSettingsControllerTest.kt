package cool.cfapps.petclinic.ai

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.redirectedUrl
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.view
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import org.springframework.web.context.WebApplicationContext

@SpringBootTest(webEnvironment = WebEnvironment.MOCK)
@ActiveProfiles("test")
class AiSettingsControllerTest {

    @Autowired
    private lateinit var webApplicationContext: WebApplicationContext

    @Autowired
    lateinit var settingsRepository: AiSettingsRepository

    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setup() {
        mockMvc = MockMvcBuilders.webAppContextSetup(webApplicationContext).build()
    }

    @Test
    fun `GET ai settings returns settings page`() {
        mockMvc.perform(get("/ai/settings"))
            .andExpect(status().isOk)
            .andExpect(view().name("ai/settings"))
    }

    @Test
    fun `POST ai settings saves and redirects`() {
        mockMvc.perform(
            post("/ai/settings")
                .param("ollamaUrl", "http://localhost:11434")
                .param("modelName", "llama3.1:8b")
                .param("enabled", "true")
        )
            .andExpect(status().is3xxRedirection)
            .andExpect(redirectedUrl("/ai/settings"))

        val saved = settingsRepository.getSettings()
        assert(saved.enabled)
        assert(saved.ollamaUrl == "http://localhost:11434")
        assert(saved.modelName == "llama3.1:8b")
    }

    @Test
    fun `POST toggle toggles enabled state`() {
        val before = settingsRepository.getSettings()
        val wasBefore = before.enabled

        mockMvc.perform(post("/ai/toggle"))
            .andExpect(status().isOk)

        val after = settingsRepository.getSettings()
        assert(after.enabled != wasBefore)
    }
}
