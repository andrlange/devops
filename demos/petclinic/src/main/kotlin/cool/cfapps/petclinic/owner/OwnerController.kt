package cool.cfapps.petclinic.owner

import cool.cfapps.petclinic.pet.PetRepository
import cool.cfapps.petclinic.visit.VisitRepository
import jakarta.validation.Valid
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.validation.BindingResult
import org.springframework.web.bind.annotation.*

@Controller
@RequestMapping("/owners")
class OwnerController(
    private val ownerRepository: OwnerRepository,
    private val petRepository: PetRepository,
    private val visitRepository: VisitRepository
) {

    @GetMapping
    fun listOwners(model: Model): String {
        model.addAttribute("owners", ownerRepository.findAll())
        return "owners/list"
    }

    @GetMapping("/{id}")
    fun ownerDetail(@PathVariable id: Long, model: Model): String {
        val owner = ownerRepository.findById(id).orElseThrow { NoSuchElementException("Owner not found") }
        val pets = petRepository.findByOwner(owner)
        val visits = pets.flatMap { visitRepository.findByPetId(it.id) }
            .sortedWith(compareBy({ it.date }, { it.time }))
        model.addAttribute("owner", owner)
        model.addAttribute("pets", pets)
        model.addAttribute("visits", visits)
        return "owners/detail"
    }

    @GetMapping("/new")
    fun newOwnerForm(model: Model): String {
        model.addAttribute("owner", Owner())
        return "owners/form"
    }

    @PostMapping("/new")
    fun createOwner(@Valid @ModelAttribute owner: Owner, bindingResult: BindingResult): String {
        if (bindingResult.hasErrors()) {
            return "owners/form"
        }
        val saved = ownerRepository.save(owner)
        return "redirect:/owners/${saved.id}"
    }

    @GetMapping("/{id}/edit")
    fun editOwnerForm(@PathVariable id: Long, model: Model): String {
        val owner = ownerRepository.findById(id).orElseThrow { NoSuchElementException("Owner not found") }
        model.addAttribute("owner", owner)
        return "owners/form"
    }

    @PostMapping("/{id}/edit")
    fun updateOwner(
        @PathVariable id: Long,
        @Valid @ModelAttribute owner: Owner,
        bindingResult: BindingResult
    ): String {
        if (bindingResult.hasErrors()) {
            return "owners/form"
        }
        owner.id = id
        ownerRepository.save(owner)
        return "redirect:/owners/$id"
    }

    @PostMapping("/{id}/delete")
    fun deleteOwner(@PathVariable id: Long): String {
        ownerRepository.deleteById(id)
        return "redirect:/owners"
    }
}
