package cool.cfapps.petclinic.pet

import org.springframework.data.jpa.repository.JpaRepository

interface PetTypeRepository : JpaRepository<PetType, Long> {

    fun findByName(name: String): PetType?
}
