package cool.cfapps.kappman.buildpack

import cool.cfapps.kappman.cfapi.CfApiService
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.GetMapping

@Controller
class BuildpackController(
    private val cfApiService: CfApiService
) {

    @GetMapping("/buildpacks")
    fun listBuildpacks(model: Model): String {
        model.addAttribute("activePage", "buildpacks")
        model.addAttribute("pageTitle", "Buildpacks")

        val buildpacks = cfApiService.listBuildpacks()
        val apps = cfApiService.listApps()

        // Map buildpack name -> list of apps using it
        val appsByBuildpack = mutableMapOf<String, MutableList<Map<String, String>>>()
        apps.forEach { app ->
            val bpNames = (app.lifecycle?.data?.get("buildpacks") as? List<*>)
                ?.filterIsInstance<String>() ?: emptyList()
            bpNames.forEach { bpName ->
                appsByBuildpack.getOrPut(bpName) { mutableListOf() }
                    .add(mapOf("name" to app.name, "guid" to app.guid, "state" to app.state))
            }
        }

        val buildpackEntries = buildpacks.map { bp ->
            val bpApps = appsByBuildpack[bp.name] ?: emptyList()
            mapOf("buildpack" to bp, "apps" to bpApps, "appCount" to bpApps.size)
        }

        model.addAttribute("buildpacks", buildpackEntries)
        return "buildpack/list"
    }
}
