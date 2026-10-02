package com.dbpprt.dieter.core.search

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.navigation.Folding
import com.dbpprt.dieter.core.navigation.NavigationFolder

/** Searchable metadata of one task or chat; transcripts are never indexed. */
data class SearchDocument(
    val id: String,
    val title: String,
    val text: String,
    val location: String,
    val updatedAt: String,
    val archived: Boolean = false,
    val chat: Boolean = false,
)

/**
 * The one task search: every query term must prefix-match a word, results
 * rank exact and leading title matches first, then recency. Case and accents
 * are ignored. Ported from the shared Apple `TaskSearchIndex`.
 */
class TaskSearchIndex(documents: List<SearchDocument>) {
    private val documents: Map<String, SearchDocument>
    private val postings = HashMap<String, MutableSet<String>>()
    private val vocabulary: List<String>

    init {
        val latest = LinkedHashMap<String, SearchDocument>()
        for (document in documents) {
            val existing = latest[document.id]
            if (existing == null || document.updatedAt >= existing.updatedAt) latest[document.id] = document
        }
        this.documents = latest.filterValues { !it.archived }
        for (document in this.documents.values) {
            for (word in words("${document.title} ${document.text} ${document.location} ${document.id}")) {
                postings.getOrPut(word) { HashSet() } += document.id
            }
        }
        vocabulary = postings.keys.sorted()
    }

    fun search(query: String, limit: Int = 30): List<SearchDocument> {
        val terms = words(query)
        if (terms.isEmpty() || limit <= 0) return emptyList()
        var matches: Set<String>? = null
        for (term in terms) {
            val ids = HashSet<String>()
            var index = lowerBound(term)
            while (index < vocabulary.size && vocabulary[index].startsWith(term)) {
                ids += postings.getValue(vocabulary[index])
                index++
            }
            matches = matches?.intersect(ids) ?: ids
            if (matches.isEmpty()) return emptyList()
        }
        val phrase = normalize(query).trim()
        return matches.orEmpty().mapNotNull(documents::get)
            .map { it to score(it, phrase, terms) }
            .sortedWith(compareByDescending<Pair<SearchDocument, Int>> { it.second }.thenByDescending { it.first.updatedAt }.thenBy { it.first.id })
            .take(limit)
            .map { it.first }
    }

    private fun score(document: SearchDocument, phrase: String, terms: List<String>): Int {
        val title = normalize(document.title)
        val titleWords = words(document.title)
        return when {
            title == phrase -> 3
            title.startsWith(phrase) -> 2
            terms.all { term -> titleWords.any { it.startsWith(term) } } -> 1
            else -> 0
        }
    }

    private fun lowerBound(term: String): Int {
        var low = 0
        var high = vocabulary.size
        while (low < high) {
            val middle = (low + high) / 2
            if (vocabulary[middle] < term) low = middle + 1 else high = middle
        }
        return low
    }

    companion object {
        fun normalize(value: String): String = Folding.fold(value)

        /** Words split on anything that is not a letter or digit. */
        fun words(value: String): List<String> = normalize(value).split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }

        /** The palette catalog: titles, task text, and where each item lives. */
        fun documents(items: List<Card>, projects: List<Project>, boards: List<Board>): List<SearchDocument> {
            val projectNames = projects.associate { it.id to it.name }
            val boardNames = boards.associate { it.id to it.name }
            return items.map { card ->
                SearchDocument(
                    id = card.id,
                    title = card.title,
                    text = listOf(card.initial_prompt, card.summary).joinToString(" "),
                    location = listOfNotNull(projectNames[card.project_id], boardNames[card.board_id]).joinToString(" · "),
                    updatedAt = card.updated_at,
                    archived = card.archived,
                    chat = Cards.isChat(card),
                )
            }.sortedWith(compareBy({ it.id }, { it.updatedAt }))
        }
    }
}

/** Substring filters for lists that search in place. */
object ListFilters {
    private fun contains(value: String, term: String) = value.contains(term, ignoreCase = true)

    /** Chats whose title, summary, project name, or folder name contains the query. */
    fun chats(chats: List<Card>, projects: List<Project>, folders: List<NavigationFolder>, query: String): List<Card> {
        val term = query.trim()
        if (term.isEmpty()) return chats
        val names = projects.associate { it.id to it.name }
        val inMatchingFolders = folders.filter { contains(it.name, term) }.flatMapTo(HashSet()) { it.itemIds }
        return chats.filter {
            contains(it.title, term) || contains(it.summary, term) || contains(names[it.project_id].orEmpty(), term) || it.id in inMatchingFolders
        }
    }

    /** Projects to show beside a chat search: all when not searching, else matching ones or ones with matching chats. */
    fun chatProjects(projects: List<Project>, matchingChats: List<Card>, query: String): List<Project> {
        if (query.isBlank()) return projects
        val withChats = matchingChats.mapTo(HashSet()) { it.project_id }
        return projects.filter { contains(it.name, query.trim()) || it.id in withChats }
    }

    /** Projects as picker options (ID to name), by name. */
    fun projectOptions(projects: List<Project>): List<Pair<String, String>> = projects.sortedBy { it.name.lowercase() }.map { it.id to it.name }

    /** Projects whose name or summary contains [query]. */
    fun projects(projects: List<Project>, query: String): List<Project> {
        val term = query.trim()
        return if (term.isEmpty()) projects else projects.filter { contains(it.name, term) || contains(it.summary, term) }
    }

    /** Boards whose name or description contains [query]. */
    fun boards(boards: List<Board>, query: String): List<Board> {
        val term = query.trim()
        return if (term.isEmpty()) boards else boards.filter { contains(it.name, term) || contains(it.description, term) }
    }

    /** Cards whose title or summary contains [query]. */
    fun cards(cards: List<Card>, query: String): List<Card> {
        val term = query.trim()
        if (term.isEmpty()) return cards
        return cards.filter { contains(it.title, term) || contains(it.summary, term) }
    }
}
