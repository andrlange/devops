package cool.cfapps.kappman.service

import cool.cfapps.kappman.cfapi.CfApiService
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping

@Controller
@RequestMapping("/marketplace")
class MarketplaceController(
    private val cfApiService: CfApiService
) {

    @GetMapping
    fun catalog(model: Model): String {
        model.addAttribute("activePage", "marketplace")
        model.addAttribute("pageTitle", "Marketplace")

        val offerings = cfApiService.listOfferings()
        val plans = cfApiService.listPlans()
        val services = cfApiService.listServiceInstances()
        val bindings = cfApiService.listBindings()

        // Group plans by offering
        val plansByOffering = plans.groupBy { plan ->
            (plan.relationships?.get("service_offering") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
        }

        // Count instances per plan
        // Service instances have a relationship to service_plan
        val instancesByPlan = services.groupBy { svc ->
            (svc.relationships?.get("service_plan") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
        }

        // Count bindings per service instance
        val bindingsByService = bindings.groupBy { binding ->
            (binding.relationships?.get("service_instance") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
        }

        val offeringEntries = offerings.map { offering ->
            val offeringPlans = plansByOffering[offering.guid] ?: emptyList()
            val offeringPlanGuids = offeringPlans.map { it.guid }.toSet()

            // Instances for this offering (across all plans)
            val offeringInstances = services.filter { svc ->
                val planGuid = (svc.relationships?.get("service_plan") as? Map<*, *>)
                    ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
                planGuid in offeringPlanGuids
            }

            // Total bindings for all instances of this offering
            val totalBindings = offeringInstances.sumOf { svc -> (bindingsByService[svc.guid] ?: emptyList()).size }

            // Plan details with instance counts
            val planDetails = offeringPlans.map { plan ->
                val planInstances = instancesByPlan[plan.guid] ?: emptyList()
                mapOf("plan" to plan, "instanceCount" to planInstances.size)
            }

            val catalogMetadata = ServiceDocs.asMetadataMap(offering.name)

            mapOf(
                "offering" to offering,
                "plans" to planDetails,
                "instanceCount" to offeringInstances.size,
                "bindingCount" to totalBindings,
                "catalogMetadata" to catalogMetadata
            )
        }

        model.addAttribute("offerings", offeringEntries)
        return "marketplace/catalog"
    }

    @GetMapping("/{offeringGuid}/plans")
    fun plans(@PathVariable offeringGuid: String, model: Model): String {
        model.addAttribute("activePage", "marketplace")
        model.addAttribute("pageTitle", "Service Plans")
        val offerings = cfApiService.listOfferings()
        val offering = offerings.find { it.guid == offeringGuid }
        model.addAttribute("offering", offering)
        model.addAttribute("plans", cfApiService.listPlans(offeringGuid))
        model.addAttribute("spaces", cfApiService.listSpaces())

        val catalogMetadata = ServiceDocs.asMetadataMap(offering?.name ?: "")
        model.addAttribute("catalogMetadata", catalogMetadata)

        return "marketplace/create-instance"
    }
}
