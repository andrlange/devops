package cool.cfapps.petclinic.pet

import jakarta.persistence.*

@Entity
@Table(name = "pet_types")
class PetType(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @Column(name = "name", unique = true)
    var name: String = ""
)
