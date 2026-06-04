package cool.cfapps.petclinic.vet

import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RequestMapping

@Controller
@RequestMapping("/vets")
class VetController(
    private val vetRepository: VetRepository
) {

    @GetMapping
    fun list(model: Model): String {
        model.addAttribute("vets", vetRepository.findAll())
        return "vets/list"
    }
}
