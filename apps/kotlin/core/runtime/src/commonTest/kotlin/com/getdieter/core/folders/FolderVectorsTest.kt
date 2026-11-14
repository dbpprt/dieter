package com.getdieter.core.folders

import com.getdieter.api.v1.FolderCounter
import com.getdieter.api.v1.FolderDeleteGuard
import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.api.v1.FolderMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/** The repository's tests/fixtures/folders/vectors.json, which the Go rules also pass. */
internal expect fun folderVectors(): String

/**
 * The Go reference's golden vectors (internal/folders): every section must give the same answer in
 * the Kotlin core, so members on every platform reconcile the same way.
 */
class FolderVectorsTest {
    private val vectors: JsonObject = Json.parseToJsonElement(folderVectors()).jsonObject

    private fun section(name: String): List<JsonObject> =
        vectors.getValue(name).jsonArray.map { it.jsonObject }

    private fun JsonObject.text(name: String): String = this[name]?.jsonPrimitive?.content ?: ""

    private fun version(element: JsonElement?): List<FolderCounter> =
        (element as? JsonArray)?.map {
            val counter = it.jsonObject
            FolderCounter(counter.text("actor"), counter.getValue("value").jsonPrimitive.long)
        } ?: emptyList()

    private fun kind(value: String): FolderEntryKind =
        when (value) {
            "file" -> FolderEntryKind.FOLDER_ENTRY_KIND_FILE
            "directory" -> FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY
            "deleted" -> FolderEntryKind.FOLDER_ENTRY_KIND_DELETED
            else -> FolderEntryKind.FOLDER_ENTRY_KIND_UNSPECIFIED
        }

    private fun entry(element: JsonElement?): FolderEntry? {
        if (element == null || element is JsonNull) return null
        val value = element.jsonObject
        return FolderEntry(
            path = value.text("path"),
            kind = kind(value.text("kind")),
            size = value["size"]?.jsonPrimitive?.long ?: 0,
            modified_nanos = value["modified"]?.jsonPrimitive?.long ?: 0,
            executable = value["executable"]?.jsonPrimitive?.boolean ?: false,
            sha256 = value.text("sha256"),
            version = version(value["version"]),
            sequence = value["sequence"]?.jsonPrimitive?.long ?: 0,
            author_id = value.text("authorId"),
            author_name = value.text("authorName"),
        )
    }

    private fun mode(value: String): FolderMode =
        when (value) {
            "send-only" -> FolderMode.FOLDER_MODE_SEND_ONLY
            "receive-only" -> FolderMode.FOLDER_MODE_RECEIVE_ONLY
            else -> FolderMode.FOLDER_MODE_TWO_WAY
        }

    private fun action(value: String): FolderAction =
        when (value) {
            "none" -> FolderAction.NONE
            "apply" -> FolderAction.APPLY
            "merge" -> FolderAction.MERGE
            "out-of-sync" -> FolderAction.OUT_OF_SYNC
            else -> fail("unknown action $value")
        }

    @Test
    fun actorsAreTheFirstEightBytesOfTheMembersHash() {
        val cases = section("actors")
        assertTrue(cases.isNotEmpty())
        for (case in cases) assertEquals(
            case.text("actor"),
            Versions.actorOf(case.text("member")),
            case.toString(),
        )
    }

    @Test
    fun versionsCompareMergeAndBumpLikeGo() {
        for (case in section("compare")) {
            val expected =
                when (case.text("expect")) {
                    "equal" -> Ordering.EQUAL
                    "before" -> Ordering.BEFORE
                    "after" -> Ordering.AFTER
                    else -> Ordering.CONCURRENT
                }
            assertEquals(
                expected,
                Versions.compare(version(case["a"]), version(case["b"])),
                case.toString(),
            )
        }
        for (case in section("merge")) assertEquals(
            version(case["expect"]),
            Versions.merge(version(case["a"]), version(case["b"])),
            case.toString(),
        )
        for (case in section("bump")) assertEquals(
            version(case["expect"]),
            Versions.bump(version(case["version"]), case.text("actor")),
            case.toString(),
        )
    }

    @Test
    fun decideMatchesEveryVector() {
        val cases = section("decide")
        assertTrue(cases.size >= 20)
        for (case in cases) {
            val name = case.text("name")
            val local = entry(case["local"])
            val remote = assertNotNull(entry(case["remote"]))
            local?.let { assertNull(FolderNames.entryProblem(it), "$name: invalid local") }
            assertNull(FolderNames.entryProblem(remote), "$name: invalid remote")
            val expect = case.getValue("expect").jsonObject
            val got = FolderReconcile.decide(local, remote, mode(case.text("mode")))
            assertEquals(action(expect.text("action")), got.action, name)
            assertEquals(expect["conflict"]?.jsonPrimitive?.boolean ?: false, got.conflict, name)
            assertEquals(expect.text("conflictCopy"), got.conflictCopy, name)
            entry(expect["result"])?.let { assertEquals(it, got.result, name) }
        }
    }

    @Test
    fun conflictNamesMatch() {
        for (case in section("conflictNames")) assertEquals(
            case.text("expect"),
            FolderReconcile.conflictName(
                case.text("path"),
                case.text("author"),
                case.getValue("modified").jsonPrimitive.long,
            ),
            case.text("path"),
        )
    }

    @Test
    fun pathValidationMatches() {
        for (case in section("validatePath")) assertEquals(
            case.getValue("valid").jsonPrimitive.boolean,
            FolderNames.validPath(case.text("path")),
            case.text("path"),
        )
    }

    @Test
    fun rulesMatch() {
        for (case in section("rules")) {
            val values = case.getValue("rules").jsonArray.map { it.jsonPrimitive.content }
            val rules =
                FolderRules.parse(
                    if (values == listOf("DEFAULT")) FolderRules.DEFAULT_RULES else values
                )
            assertEquals(
                case.getValue("included").jsonPrimitive.boolean,
                FolderRules.included(case.text("path"), rules),
                case.toString(),
            )
        }
        for (invalid in vectors.getValue("invalidRules").jsonArray) {
            val values = invalid.jsonArray.map { it.jsonPrimitive.content }
            assertNull(FolderRules.parseOrNull(values), values.toString())
        }
    }

    @Test
    fun guardPortabilityFoldKeysAndOrderMatch() {
        for (case in section("guard")) {
            val policy =
                when (case.text("policy")) {
                    "strict" -> FolderDeleteGuard.FOLDER_DELETE_GUARD_STRICT
                    "off" -> FolderDeleteGuard.FOLDER_DELETE_GUARD_OFF
                    else -> FolderDeleteGuard.FOLDER_DELETE_GUARD_DEFAULT
                }
            assertEquals(
                case.getValue("trips").jsonPrimitive.boolean,
                FolderGuard.trips(
                    policy,
                    case.getValue("deletions").jsonPrimitive.int,
                    case.getValue("total").jsonPrimitive.int,
                ),
                case.toString(),
            )
        }
        for (case in section("portable")) assertEquals(
            case.getValue("portable").jsonPrimitive.boolean,
            FolderNames.portable(case.text("path")),
            case.text("path"),
        )
        for (case in section("foldKeys")) assertEquals(
            case.text("expect"),
            FolderNames.foldKey(case.text("path")),
        )
        val ordered = vectors.getValue("ordered").jsonObject
        val entries = ordered.getValue("entries").jsonArray.map { assertNotNull(entry(it)) }
        assertEquals(
            ordered.getValue("expect").jsonArray.map { it.jsonPrimitive.content },
            FolderGuard.ordered(entries).map { it.path },
        )
    }

    @Test
    fun everySectionIsCovered() {
        val covered =
            setOf(
                "about",
                "actors",
                "compare",
                "merge",
                "bump",
                "decide",
                "conflictNames",
                "validatePath",
                "rules",
                "invalidRules",
                "guard",
                "portable",
                "foldKeys",
                "ordered",
            )
        assertEquals(emptySet(), vectors.keys - covered, "a new vectors section needs a test")
    }
}
