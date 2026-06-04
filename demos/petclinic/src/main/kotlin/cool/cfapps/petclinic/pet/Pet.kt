package cool.cfapps.petclinic.pet

import cool.cfapps.petclinic.owner.Owner
import jakarta.persistence.*
import jakarta.validation.constraints.NotBlank
import java.time.LocalDate

@Entity
@Table(name = "pets")
class Pet(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @Column(name = "name")
    @field:NotBlank
    var name: String = "",

    @Column(name = "birth_date")
    var birthDate: LocalDate = LocalDate.now(),

    @Column(name = "image_url", nullable = true)
    var imageUrl: String? = null,

    @ManyToOne(fetch = FetchType.EAGER)
    @JoinColumn(name = "type_id")
    var type: PetType = PetType(),

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "owner_id")
    var owner: Owner = Owner()
)
