package com.getdieter.core.channels

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.KVEntry
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.ChannelSettingChange
import com.getdieter.client.v1.ChannelSettingMode
import com.getdieter.client.v1.ChannelSettingScope
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.testing.offlineSessions
import com.getdieter.core.trust.DeviceTrust
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import okio.ByteString.Companion.encodeUtf8

class ChannelSettingsTest {
    private fun entry(key: String, json: String, deleted: Boolean = false) =
        key to
            KVEntry(
                namespace = ChannelSwitches.NAMESPACE,
                key = key,
                value_json = json.encodeUtf8(),
                deleted = deleted,
            )

    private val ON = ChannelSettingMode.CHANNEL_SETTING_MODE_ON
    private val OFF = ChannelSettingMode.CHANNEL_SETTING_MODE_OFF
    private val INHERIT = ChannelSettingMode.CHANNEL_SETTING_MODE_INHERIT

    @Test
    fun theNamespaceHoldsTheGlobalSwitchAndOverrides() {
        val switches =
            ChannelSwitches.parse(
                mapOf(
                    entry("channels", "true"),
                    entry("channels.project.p1", "\"off\""),
                    entry("channels.project.p2", "\"on\""),
                    entry("channels.board.b1", "\"on\""),
                    // Deleted, malformed and foreign values inherit.
                    entry("channels.board.b2", "\"off\"", deleted = true),
                    entry("channels.board.b3", "true"),
                    entry("channels.project.p3", "{"),
                    entry("other", "\"on\""),
                )
            )
        assertEquals(
            ChannelSwitches(
                global = true,
                projects = mapOf("p1" to false, "p2" to true),
                boards = mapOf("b1" to true),
            ),
            switches,
        )
        assertFalse(ChannelSwitches.parse(emptyMap()).anyEnabled)
        assertFalse(ChannelSwitches.parse(mapOf(entry("channels", "false"))).global)
    }

    @Test
    fun aBoardOverridesItsProjectWhichOverridesTheGlobalSwitch() {
        val switches =
            ChannelSwitches(
                global = false,
                projects = mapOf("p1" to true),
                boards = mapOf("b1" to false, "b2" to true),
            )
        assertTrue(switches.enabled("p1"))
        assertFalse(switches.enabled("p1", "b1"))
        assertTrue(switches.enabled("p1", "b9"))
        assertFalse(switches.enabled("p2"))
        assertTrue(switches.enabled("p2", "b2"))
        // A chat has no board.
        assertTrue(switches.enabled("p1", ""))
        // A project channel is in use when any of its boards switches it on.
        assertTrue(switches.projectEnabled("p2", listOf("b2")))
        assertFalse(switches.projectEnabled("p2", listOf("b1")))
        assertTrue(switches.anyEnabled)
    }

    @Test
    fun rowsShowTheModeAndTheInheritedValue() {
        val switches = ChannelSwitches(global = true, projects = mapOf("p2" to false))
        val slice =
            ChannelSettingRules.slice(
                switches,
                listOf(Project(id = "p2", name = "beta"), Project(id = "p1", name = "Alpha")),
                listOf(
                    Board(id = "b2", project_id = "p2", name = "Main"),
                    Board(id = "b1", project_id = "p1", name = "Main"),
                ),
            )
        assertTrue(slice.global)
        assertEquals(listOf("p1", "p2"), slice.projects.map { it.id })
        assertEquals(listOf("Inherit (On)", "Off"), slice.projects.map { it.label })
        assertEquals(listOf(true, false), slice.projects.map { it.effective })
        assertEquals(
            listOf("Inherit (On)", "On", "Off"),
            slice.projects[0].options.map { it.label },
        )
        assertEquals("Follows the global setting (On).", slice.projects[0].detail)
        // A board inherits its project's resolution.
        assertEquals(listOf("b1", "b2"), slice.boards.map { it.id })
        assertEquals(listOf("Inherit (On)", "Inherit (Off)"), slice.boards.map { it.label })
        assertEquals("Follows the project (Off).", slice.boards[1].detail)
        assertEquals("Follows the global setting (On).", slice.boards[0].detail)
    }

    @Test
    fun changesApplyAndBecomeRequests() {
        val change = ChannelSettingChange(ChannelSettingScope.CHANNEL_SETTING_SCOPE_BOARD, "b1", ON)
        val switches = ChannelSwitches().with(change)
        assertEquals(mapOf("b1" to true), switches.boards)
        assertTrue(switches.shows(change))
        val inherit = change.copy(mode = INHERIT)
        assertEquals(emptyMap(), switches.with(inherit).boards)
        assertEquals(
            true,
            ChannelSwitches()
                .with(
                    ChannelSettingChange(ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL, "", ON)
                )
                .global,
        )

        val request = ChannelSettingRules.request(inherit)
        assertEquals(
            listOf("board", "b1", "inherit"),
            listOf(request.scope, request.id, request.value_),
        )
        val global =
            ChannelSettingRules.request(
                ChannelSettingChange(ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL, "x", OFF)
            )
        assertEquals(listOf("global", "", "off"), listOf(global.scope, global.id, global.value_))
        assertFailsWith<CoreException> {
            ChannelSettingRules.request(
                ChannelSettingChange(ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL, "", INHERIT)
            )
        }
        assertFailsWith<CoreException> {
            ChannelSettingRules.request(
                ChannelSettingChange(ChannelSettingScope.CHANNEL_SETTING_SCOPE_PROJECT, "", ON)
            )
        }
    }

    @Test
    fun theStoreFollowsTheAccountViewAndDropsAFailedChange() = runTest {
        val store = ChannelSettingsStore(offlineSessions(), { emptyList() }, object : CoreLogger {})
        store.apply(mapOf(entry("channels", "true")))
        assertTrue(store.view.value.switches.global)
        val change =
            ChannelSettingChange(ChannelSettingScope.CHANNEL_SETTING_SCOPE_PROJECT, "p1", OFF)
        // No machine is reachable: the change is not kept and the failure shows.
        assertFailsWith<CoreException> { store.set(change) }
        assertEquals(ChannelSwitches(global = true), store.view.value.switches)
        assertEquals("No machine is reachable to save the setting.", store.view.value.error)
        assertFalse(store.view.value.saving)
        store.apply(mapOf(entry("channels", "true"), entry("channels.project.p1", "\"off\"")))
        assertFalse(store.view.value.switches.enabled("p1"))
    }

    @Test
    fun aMachineThatCannotSaveDoesNotKeepTheNextFromSaving() = runTest {
        val tried = mutableListOf<String>()
        var accepts = setOf("office")
        val store =
            ChannelSettingsStore(
                { machine, _ ->
                    tried += machine
                    when (machine) {
                        in accepts -> Unit
                        "untrusted" ->
                            throw CoreException(
                                FailureKind.TRANSIENT,
                                DeviceTrust.MACHINE_NOT_TRUSTED,
                            )
                        else -> throw CoreException(FailureKind.TRANSIENT, "offline")
                    }
                },
                { listOf("untrusted", "offline", "office") },
                object : CoreLogger {},
            )
        val change = ChannelSettingChange(ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL, "", ON)
        // This device's own machine is untrusted and the next one fails: the third saves it.
        store.set(change)
        assertEquals(listOf("untrusted", "offline", "office"), tried)
        assertEquals(null, store.view.value.error)
        assertTrue(store.view.value.switches.global)

        // When none saves, the last failure shows.
        accepts = emptySet()
        tried.clear()
        assertFailsWith<CoreException> { store.set(change.copy(mode = OFF)) }
        assertEquals(listOf("untrusted", "offline", "office"), tried)
        assertEquals("offline", store.view.value.error)
    }
}
