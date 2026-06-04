package cool.cfapps.petclinic.vet

import jakarta.persistence.*

@Entity
@Table(name = "specialties")
class Specialty(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @Column(name = "name", unique = true)
    var name: String = ""
)
