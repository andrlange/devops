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
