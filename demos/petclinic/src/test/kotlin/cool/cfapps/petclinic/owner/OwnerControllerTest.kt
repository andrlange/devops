package cool.cfapps.petclinic.owner

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.BeforeEach
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.view
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import org.springframework.web.context.WebApplicationContext

@SpringBootTest(webEnvironment = WebEnvironment.MOCK)
@ActiveProfiles("test")
class OwnerControllerTest {

    @Autowired
    private lateinit var webApplicationContext: WebApplicationContext

    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setup() {
        mockMvc = MockMvcBuilders.webAppContextSetup(webApplicationContext).build()
    }

    @Test
    fun `list owners returns 200`() {
        mockMvc.perform(get("/owners"))
            .andExpect(status().isOk)
            .andExpect(view().name("owners/list"))
    }

    @Test
    fun `new owner form returns 200`() {
        mockMvc.perform(get("/owners/new"))
            .andExpect(status().isOk)
            .andExpect(view().name("owners/form"))
    }

    @Test
    fun `search owners returns 200`() {
        mockMvc.perform(get("/owners").param("search", "Franklin"))
            .andExpect(status().isOk)
            .andExpect(view().name("owners/list"))
    }
}
