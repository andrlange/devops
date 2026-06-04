package cool.cfapps.petclinic.pet

import cool.cfapps.petclinic.owner.OwnerRepository
import cool.cfapps.petclinic.visit.VisitRepository
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*

@Controller
@RequestMapping("/pets")
class PetController(
    private val petRepository: PetRepository,
    private val petTypeRepository: PetTypeRepository,
    private val ownerRepository: OwnerRepository,
    private val visitRepository: VisitRepository
) {

    @GetMapping
    fun list(model: Model): String {
        model.addAttribute("pets", petRepository.findAll())
        model.addAttribute("petTypes", petTypeRepository.findAll())
        return "pets/list"
    }

    @GetMapping("/{id}")
    fun detail(@PathVariable id: Long, model: Model): String {
        val pet = petRepository.findById(id).orElseThrow { NoSuchElementException("Pet not found") }
        val visits = visitRepository.findByPetId(id)
        model.addAttribute("pet", pet)
        model.addAttribute("visits", visits)
        return "pets/detail"
    }

    @GetMapping("/new")
    fun newPetForm(model: Model): String {
        model.addAttribute("pet", Pet())
        model.addAttribute("owners", ownerRepository.findAll())
        model.addAttribute("petTypes", petTypeRepository.findAll())
        return "pets/form"
    }

    @PostMapping("/new")
    fun createPet(
        @ModelAttribute pet: Pet,
        @RequestParam ownerId: Long,
        @RequestParam typeId: Long
    ): String {
        val owner = ownerRepository.findById(ownerId).orElseThrow { NoSuchElementException("Owner not found") }
        val type = petTypeRepository.findById(typeId).orElseThrow { NoSuchElementException("Pet type not found") }
        pet.owner = owner
        pet.type = type
        val saved = petRepository.save(pet)
        return "redirect:/pets/${saved.id}"
    }

    @GetMapping("/{id}/edit")
    fun editPetForm(@PathVariable id: Long, model: Model): String {
        val pet = petRepository.findById(id).orElseThrow { NoSuchElementException("Pet not found") }
        model.addAttribute("pet", pet)
        model.addAttribute("owners", ownerRepository.findAll())
        model.addAttribute("petTypes", petTypeRepository.findAll())
        return "pets/form"
    }

    @PostMapping("/{id}/edit")
    fun updatePet(
        @PathVariable id: Long,
        @ModelAttribute pet: Pet,
        @RequestParam ownerId: Long,
        @RequestParam typeId: Long
    ): String {
        val existing = petRepository.findById(id).orElseThrow { NoSuchElementException("Pet not found") }
        val owner = ownerRepository.findById(ownerId).orElseThrow { NoSuchElementException("Owner not found") }
        val type = petTypeRepository.findById(typeId).orElseThrow { NoSuchElementException("Pet type not found") }
        existing.name = pet.name
        existing.birthDate = pet.birthDate
        existing.imageUrl = pet.imageUrl
        existing.owner = owner
        existing.type = type
        petRepository.save(existing)
        return "redirect:/pets/$id"
    }

    @PostMapping("/{id}/delete")
    fun deletePet(@PathVariable id: Long): String {
        petRepository.deleteById(id)
        return "redirect:/pets"
    }
}
