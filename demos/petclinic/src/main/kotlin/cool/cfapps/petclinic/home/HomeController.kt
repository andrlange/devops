package cool.cfapps.petclinic.home

import cool.cfapps.petclinic.owner.OwnerRepository
import cool.cfapps.petclinic.pet.PetRepository
import cool.cfapps.petclinic.pet.PetTypeRepository
import cool.cfapps.petclinic.vet.VetRepository
import cool.cfapps.petclinic.visit.VisitRepository
import cool.cfapps.petclinic.visit.VisitStatus
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.GetMapping
import java.time.LocalDate

@Controller
class HomeController(
    private val ownerRepository: OwnerRepository,
    private val petRepository: PetRepository,
    private val vetRepository: VetRepository,
    private val visitRepository: VisitRepository,
    private val petTypeRepository: PetTypeRepository
) {

    @GetMapping("/")
    fun home(model: Model): String {
        val today = LocalDate.now()

        model.addAttribute("totalOwners", ownerRepository.count())
        model.addAttribute("totalPets", petRepository.count())
        model.addAttribute("totalVets", vetRepository.count())

        // Upcoming appointments: scheduled visits with date >= today
        val upcomingVisits = visitRepository
            .findByDateBetweenOrderByDateAscTimeAsc(today, today.plusYears(1))
            .filter { it.status == VisitStatus.SCHEDULED }
        model.addAttribute("upcomingAppointments", upcomingVisits.size)

        // Recent (next 10) upcoming appointments
        model.addAttribute("recentAppointments", upcomingVisits.take(10))

        // Pets by type: map of type name -> count
        val allTypes = petTypeRepository.findAll()
        val petsByType = allTypes.associate { type ->
            type.name to petRepository.findByType(type).size.toLong()
        }.filter { it.value > 0 }
        model.addAttribute("petsByType", petsByType)

        return "home"
    }
}
