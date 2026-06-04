package cool.cfapps.petclinic.ai

import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface AiSettingsRepository : JpaRepository<AiSettings, Long>

fun AiSettingsRepository.getSettings(): AiSettings =
    findById(1).orElseGet { save(AiSettings()) }
