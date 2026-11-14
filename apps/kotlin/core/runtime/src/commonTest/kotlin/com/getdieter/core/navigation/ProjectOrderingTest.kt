package com.getdieter.core.navigation

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Project
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class ProjectOrderingTest {
    @Test
    fun activityLeadsUntilSavedPositionsOverrideIt() {
        val projects =
            listOf(
                Project(id = "alpha", name = "Alpha", updated_at = "2026-01-02T00:00:00Z"),
                Project(id = "beta", name = "Beta", updated_at = "2026-01-03T00:00:00Z"),
                Project(id = "gamma", name = "Gamma", updated_at = "2026-01-01T00:00:00Z"),
                Project(
                    id = "archived",
                    name = "Archived",
                    archived = true,
                    updated_at = "2026-12-01T00:00:00Z",
                ),
            )
        val cards =
            listOf(
                Card(id = "old", project_id = "alpha", last_activity_at = "2026-06-01T00:00:00Z"),
                Card(id = "new", project_id = "gamma", last_activity_at = "2026-06-03T00:00:00Z"),
                Card(
                    id = "running",
                    project_id = "beta",
                    runtime_updated_at = "2026-06-02T00:00:00Z",
                ),
                Card(
                    id = "archived-card",
                    project_id = "beta",
                    archived = true,
                    last_activity_at = "2026-06-04T00:00:00Z",
                ),
            )

        val automatic = ProjectOrdering.byActivity(projects, cards)
        assertEquals(listOf("gamma", "beta", "alpha"), automatic)
        assertEquals(
            listOf("beta", "gamma", "alpha"),
            SidebarProjects.of(
                    automatic,
                    listOf("beta"),
                    emptyList(),
                    emptyList(),
                    emptyList(),
                )
                .order,
            "manual positions lead while the remaining projects retain their activity order",
        )

        val kv =
            SharedKv(
                    "navigation",
                    offlineSessions().kvMachines(),
                    acceptor = { null },
                    SilentLogger,
                )
                .also {
                    it.bind(CoreStorage(FakeFileSystem(), "/state".toPath()))
                }
        val editor = NavigationEditor(kv)
        editor.setProjectOrder(listOf("beta", "gamma", "alpha"))
        assertEquals(
            listOf("beta", "gamma", "alpha"),
            NavigationLayout(kv.values.value).projectOrder(automatic),
        )
        ProjectOrdering.replaceSavedOrder(kv, emptyList())
        val reset = NavigationLayout(kv.values.value)
        assertEquals(emptyList(), reset.savedProjectOrder())
        assertEquals(
            automatic,
            reset.projectOrder(automatic),
            "clearing custom positions restores activity order",
        )
    }
}
