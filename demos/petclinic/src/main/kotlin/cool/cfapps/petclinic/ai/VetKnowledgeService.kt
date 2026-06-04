package cool.cfapps.petclinic.ai

import cool.cfapps.petclinic.pet.Pet
import cool.cfapps.petclinic.visit.Visit
import org.springframework.stereotype.Service
import java.time.LocalDate
import java.time.Period

@Service
class VetKnowledgeService(
    private val repository: VetKnowledgeRepository
) {
    private val stopWords = setOf(
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "can", "shall", "to", "of", "in", "for",
        "on", "with", "at", "by", "from", "as", "into", "about", "like",
        "through", "after", "over", "between", "out", "against", "during",
        "without", "before", "under", "around", "among", "i", "me", "my",
        "we", "our", "you", "your", "he", "she", "it", "they", "them",
        "what", "which", "who", "when", "where", "why", "how", "not", "no",
        "and", "but", "or", "if", "then", "so", "than", "too", "very",
        "just", "don", "t", "s"
    )

    fun extractSearchTerms(question: String): String {
        if (question.isBlank()) return ""
        return question.lowercase()
            .replace(Regex("[^a-z0-9\\s]"), "")
            .split("\\s+".toRegex())
            .filter { it.isNotBlank() && it !in stopWords && it.length > 1 }
            .distinct()
            .joinToString(" & ")
    }

    fun searchKnowledge(question: String, petType: String? = null, limit: Int = 3): List<VetKnowledge> {
        val terms = extractSearchTerms(question)
        if (terms.isBlank()) return emptyList()
        return try {
            repository.searchByFts(terms, petType ?: "", limit)
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun buildContext(articles: List<VetKnowledge>, pet: Pet? = null, visits: List<Visit>? = null): String {
        val sb = StringBuilder()
        val today = LocalDate.now()

        sb.appendLine("## Current Date: $today")
        sb.appendLine()

        if (pet != null) {
            val age = Period.between(pet.birthDate, today)
            val ageStr = when {
                age.years > 0 -> "${age.years} year${if (age.years != 1) "s" else ""} and ${age.months} month${if (age.months != 1) "s" else ""}"
                age.months > 0 -> "${age.months} month${if (age.months != 1) "s" else ""}"
                else -> "${age.days} day${if (age.days != 1) "s" else ""}"
            }
            sb.appendLine("## Pet Information")
            sb.appendLine("Name: ${pet.name}")
            sb.appendLine("Type: ${pet.type.name}")
            sb.appendLine("Birth Date: ${pet.birthDate}")
            sb.appendLine("Age: $ageStr")
            sb.appendLine("Owner: ${pet.owner.firstName} ${pet.owner.lastName}")
            if (!visits.isNullOrEmpty()) {
                sb.appendLine("Recent visits:")
                visits.takeLast(5).forEach { visit ->
                    sb.appendLine("- ${visit.date}: ${visit.description} (${visit.status}, Dr. ${visit.vet.lastName})")
                }
            }
            sb.appendLine()
        }

        if (articles.isNotEmpty()) {
            sb.appendLine("## Veterinary Knowledge Base")
            articles.forEach { article ->
                sb.appendLine("### ${article.title}")
                sb.appendLine(article.content)
                sb.appendLine()
            }
        }

        return sb.toString()
    }
}
