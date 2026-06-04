package cool.cfapps.petclinic.owner

import cool.cfapps.petclinic.pet.Pet
import jakarta.persistence.*
import jakarta.validation.constraints.Email
import jakarta.validation.constraints.NotBlank

@Entity
@Table(name = "owners")
class Owner(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @Column(name = "first_name")
    @field:NotBlank
    var firstName: String = "",

    @Column(name = "last_name")
    @field:NotBlank
    var lastName: String = "",

    @Column(name = "address")
    @field:NotBlank
    var address: String = "",

    @Column(name = "city")
    @field:NotBlank
    var city: String = "",

    @Column(name = "telephone")
    @field:NotBlank
    var telephone: String = "",

    @Column(name = "email")
    @field:Email
    var email: String = "",

    @OneToMany(mappedBy = "owner", cascade = [CascadeType.ALL], orphanRemoval = true, fetch = FetchType.LAZY)
    var pets: MutableSet<Pet> = mutableSetOf()
)
