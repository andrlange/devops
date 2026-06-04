package cool.cfapps.petclinic.visit

import cool.cfapps.petclinic.pet.Pet
import cool.cfapps.petclinic.vet.Vet
import jakarta.persistence.*
import java.time.LocalDate
import java.time.LocalTime

@Entity
@Table(name = "visits")
class Visit(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @ManyToOne(fetch = FetchType.EAGER)
    @JoinColumn(name = "pet_id")
    var pet: Pet = Pet(),

    @ManyToOne(fetch = FetchType.EAGER)
    @JoinColumn(name = "vet_id")
    var vet: Vet = Vet(),

    @Column(name = "visit_date")
    var date: LocalDate = LocalDate.now(),

    @Column(name = "visit_time")
    var time: LocalTime = LocalTime.now(),

    @Column(name = "description")
    var description: String = "",

    @Enumerated(EnumType.STRING)
    @Column(name = "status")
    var status: VisitStatus = VisitStatus.SCHEDULED
)
