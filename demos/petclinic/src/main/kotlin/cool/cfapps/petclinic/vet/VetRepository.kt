package cool.cfapps.petclinic.vet

import org.springframework.data.jpa.repository.JpaRepository

interface VetRepository : JpaRepository<Vet, Long>
