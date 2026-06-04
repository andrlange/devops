package cool.cfapps.petclinic.vet

import org.springframework.data.jpa.repository.JpaRepository

interface SpecialtyRepository : JpaRepository<Specialty, Long>
