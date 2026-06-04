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
