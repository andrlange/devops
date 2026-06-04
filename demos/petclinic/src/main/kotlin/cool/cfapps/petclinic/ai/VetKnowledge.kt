package cool.cfapps.petclinic.ai

import jakarta.persistence.*

@Entity
@Table(name = "vet_knowledge")
class VetKnowledge(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @Column(name = "category")
    var category: String = "",

    @Column(name = "pet_type")
    var petType: String? = null,

    @Column(name = "title")
    var title: String = "",

    @Column(name = "content", columnDefinition = "TEXT")
    var content: String = ""
)
