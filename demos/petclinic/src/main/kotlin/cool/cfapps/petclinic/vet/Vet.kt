package cool.cfapps.petclinic.vet

import jakarta.persistence.*

@Entity
@Table(name = "vets")
class Vet(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @Column(name = "first_name")
    var firstName: String = "",

    @Column(name = "last_name")
    var lastName: String = "",

    @ManyToMany(fetch = FetchType.EAGER)
    @JoinTable(
        name = "vet_specialties",
        joinColumns = [JoinColumn(name = "vet_id")],
        inverseJoinColumns = [JoinColumn(name = "specialty_id")]
    )
    var specialties: MutableSet<Specialty> = mutableSetOf()
)
