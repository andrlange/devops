package cool.cfapps.petclinic.visit

import cool.cfapps.petclinic.pet.PetRepository
import cool.cfapps.petclinic.vet.VetRepository
import org.springframework.format.annotation.DateTimeFormat
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

data class CalendarDay(
    val date: LocalDate?,
    val dayOfMonth: Int,
    val visitCount: Int = 0,
    val isToday: Boolean = false,
    val isCurrentMonth: Boolean = true
)

@Controller
@RequestMapping("/appointments")
class VisitController(
    private val visitRepository: VisitRepository,
    private val petRepository: PetRepository,
    private val vetRepository: VetRepository
) {

    @GetMapping
    fun calendar(
        @RequestParam(required = false) year: Int?,
        @RequestParam(required = false) month: Int?,
        model: Model
    ): String {
        val now = LocalDate.now()
        val y = year ?: now.year
        val m = month ?: now.monthValue

        val yearMonth = YearMonth.of(y, m)
        val firstOfMonth = yearMonth.atDay(1)
        val lastOfMonth = yearMonth.atEndOfMonth()

        // Query visits for the month
        val visits = visitRepository.findByDateBetweenOrderByDateAscTimeAsc(firstOfMonth, lastOfMonth)
        val visitCountByDay = visits.groupBy { it.date.dayOfMonth }.mapValues { it.value.size }

        // Build calendar grid with padding days
        val calendarDays = mutableListOf<CalendarDay>()

        // Monday = 1, Sunday = 7 (ISO)
        val firstDayOfWeek = firstOfMonth.dayOfWeek.value // 1=Mon .. 7=Sun
        val paddingBefore = firstDayOfWeek - 1

        // Previous month padding
        val prevMonth = yearMonth.minusMonths(1)
        val prevMonthLastDay = prevMonth.atEndOfMonth().dayOfMonth
        for (i in paddingBefore downTo 1) {
            val day = prevMonthLastDay - i + 1
            val date = prevMonth.atDay(day)
            calendarDays.add(CalendarDay(
                date = date,
                dayOfMonth = day,
                isCurrentMonth = false
            ))
        }

        // Current month days
        for (day in 1..lastOfMonth.dayOfMonth) {
            val date = yearMonth.atDay(day)
            calendarDays.add(CalendarDay(
                date = date,
                dayOfMonth = day,
                visitCount = visitCountByDay[day] ?: 0,
                isToday = date == now,
                isCurrentMonth = true
            ))
        }

        // Next month padding to fill grid (complete last row)
        val totalCells = calendarDays.size
        val remainder = totalCells % 7
        if (remainder != 0) {
            val paddingAfter = 7 - remainder
            val nextMonth = yearMonth.plusMonths(1)
            for (day in 1..paddingAfter) {
                val date = nextMonth.atDay(day)
                calendarDays.add(CalendarDay(
                    date = date,
                    dayOfMonth = day,
                    isCurrentMonth = false
                ))
            }
        }

        // Previous/next month navigation
        val prev = yearMonth.minusMonths(1)
        val next = yearMonth.plusMonths(1)

        model.addAttribute("year", y)
        model.addAttribute("month", m)
        model.addAttribute("monthName", yearMonth.month.getDisplayName(TextStyle.FULL, Locale.ENGLISH))
        model.addAttribute("calendarDays", calendarDays)
        model.addAttribute("prevYear", prev.year)
        model.addAttribute("prevMonth", prev.monthValue)
        model.addAttribute("nextYear", next.year)
        model.addAttribute("nextMonth", next.monthValue)

        return "visits/calendar"
    }

    @GetMapping("/day")
    fun day(
        @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) date: LocalDate,
        model: Model
    ): String {
        val visits = visitRepository.findByDateOrderByTimeAsc(date)
        val formatter = DateTimeFormatter.ofPattern("EEEE, MMMM d, yyyy", Locale.ENGLISH)

        model.addAttribute("visits", visits)
        model.addAttribute("date", date)
        model.addAttribute("formattedDate", date.format(formatter))

        return "visits/day"
    }

    @GetMapping("/new")
    fun newForm(
        @RequestParam(required = false) petId: Long?,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) date: LocalDate?,
        model: Model
    ): String {
        val visit = Visit()
        if (date != null) {
            visit.date = date
        }
        model.addAttribute("visit", visit)
        model.addAttribute("pets", petRepository.findAll())
        model.addAttribute("vets", vetRepository.findAll())
        model.addAttribute("selectedPetId", petId)
        return "visits/form"
    }

    @PostMapping("/new")
    fun create(
        @RequestParam petId: Long,
        @RequestParam vetId: Long,
        @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) date: LocalDate,
        @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.TIME) time: LocalTime,
        @RequestParam(required = false, defaultValue = "") description: String,
        @RequestParam(required = false, defaultValue = "SCHEDULED") status: String
    ): String {
        val pet = petRepository.findById(petId).orElseThrow { NoSuchElementException("Pet not found") }
        val vet = vetRepository.findById(vetId).orElseThrow { NoSuchElementException("Vet not found") }
        val visit = Visit(
            pet = pet,
            vet = vet,
            date = date,
            time = time,
            description = description,
            status = VisitStatus.valueOf(status)
        )
        visitRepository.save(visit)
        return "redirect:/appointments/day?date=$date"
    }

    @GetMapping("/{id}/edit")
    fun editForm(@PathVariable id: Long, model: Model): String {
        val visit = visitRepository.findById(id).orElseThrow { NoSuchElementException("Visit not found") }
        model.addAttribute("visit", visit)
        model.addAttribute("pets", petRepository.findAll())
        model.addAttribute("vets", vetRepository.findAll())
        model.addAttribute("selectedPetId", visit.pet.id)
        return "visits/form"
    }

    @PostMapping("/{id}/edit")
    fun update(
        @PathVariable id: Long,
        @RequestParam petId: Long,
        @RequestParam vetId: Long,
        @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) date: LocalDate,
        @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.TIME) time: LocalTime,
        @RequestParam(required = false, defaultValue = "") description: String,
        @RequestParam(required = false, defaultValue = "SCHEDULED") status: String
    ): String {
        val existing = visitRepository.findById(id).orElseThrow { NoSuchElementException("Visit not found") }
        val pet = petRepository.findById(petId).orElseThrow { NoSuchElementException("Pet not found") }
        val vet = vetRepository.findById(vetId).orElseThrow { NoSuchElementException("Vet not found") }
        existing.pet = pet
        existing.vet = vet
        existing.date = date
        existing.time = time
        existing.description = description
        existing.status = VisitStatus.valueOf(status)
        visitRepository.save(existing)
        return "redirect:/appointments/day?date=$date"
    }

    @PostMapping("/{id}/delete")
    fun delete(@PathVariable id: Long): String {
        visitRepository.deleteById(id)
        return "redirect:/appointments"
    }

    @PostMapping("/{id}/status")
    fun updateStatus(
        @PathVariable id: Long,
        @RequestParam status: String
    ): String {
        val visit = visitRepository.findById(id).orElseThrow { NoSuchElementException("Visit not found") }
        visit.status = VisitStatus.valueOf(status)
        visitRepository.save(visit)
        return "redirect:/appointments/day?date=${visit.date}"
    }
}
