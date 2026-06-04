package cool.cfapps.petclinic.visit

import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.test.context.ActiveProfiles
import java.time.LocalDate
import org.assertj.core.api.Assertions.assertThat

@SpringBootTest
@ActiveProfiles("test")
class VisitRepositoryTest {

    @Autowired
    private lateinit var visitRepository: VisitRepository

    @Test
    fun `find visits by date range`() {
        val start = LocalDate.of(2024, 1, 1)
        val end = LocalDate.of(2024, 12, 31)
        val visits = visitRepository.findByDateBetweenOrderByDateAscTimeAsc(start, end)
        assertThat(visits).isNotNull
    }

    @Test
    fun `find visits by status`() {
        val visits = visitRepository.findByStatus(VisitStatus.SCHEDULED)
        assertThat(visits).isNotNull
    }

    @Test
    fun `count visits by date range`() {
        val start = LocalDate.of(2024, 1, 1)
        val end = LocalDate.of(2034, 12, 31)
        val count = visitRepository.countByDateBetween(start, end)
        assertThat(count).isGreaterThanOrEqualTo(0)
    }
}
