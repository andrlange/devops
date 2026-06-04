package cool.cfapps.petclinic.owner

import org.springframework.data.jpa.repository.EntityGraph
import org.springframework.data.jpa.repository.JpaRepository

interface OwnerRepository : JpaRepository<Owner, Long> {

    fun findByLastNameContainingIgnoreCase(lastName: String): List<Owner>

    fun findByFirstNameContainingIgnoreCaseOrLastNameContainingIgnoreCase(
        firstName: String,
        lastName: String
    ): List<Owner>

    @EntityGraph(attributePaths = ["pets"])
    override fun findAll(): List<Owner>
}
