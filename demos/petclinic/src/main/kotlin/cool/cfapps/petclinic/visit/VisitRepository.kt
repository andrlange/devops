package cool.cfapps.petclinic.visit

import org.springframework.data.jpa.repository.JpaRepository
import java.time.LocalDate

interface VisitRepository : JpaRepository<Visit, Long> {

    fun findByDateBetweenOrderByDateAscTimeAsc(start: LocalDate, end: LocalDate): List<Visit>

    fun findByPetId(petId: Long): List<Visit>

    fun findByVetId(vetId: Long): List<Visit>

    fun findByStatus(status: VisitStatus): List<Visit>

    fun findByDateOrderByTimeAsc(date: LocalDate): List<Visit>

    fun countByDateBetween(start: LocalDate, end: LocalDate): Long
}
