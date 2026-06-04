package cool.cfapps.petclinic.pet

import cool.cfapps.petclinic.owner.Owner
import org.springframework.data.jpa.repository.EntityGraph
import org.springframework.data.jpa.repository.JpaRepository

interface PetRepository : JpaRepository<Pet, Long> {

    @EntityGraph(attributePaths = ["owner", "type"])
    override fun findAll(): List<Pet>

    fun findByOwner(owner: Owner): List<Pet>

    fun findByType(type: PetType): List<Pet>

    @EntityGraph(attributePaths = ["owner", "type"])
    fun findByNameContainingIgnoreCase(name: String): List<Pet>

    @EntityGraph(attributePaths = ["owner", "type"])
    fun findByTypeNameIgnoreCase(typeName: String): List<Pet>
}
