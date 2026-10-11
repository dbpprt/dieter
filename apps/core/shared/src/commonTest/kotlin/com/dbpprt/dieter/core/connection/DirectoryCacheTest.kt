package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.api.gateway.v1.Daemon
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.machines.MachineChoice
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.test.*
import kotlin.time.Instant
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class DirectoryCacheTest {
    @Test
    fun cachedPresenceNeverAuthorizesRoutingAndIsIsolatedByAccount() {
        val fs = FakeFileSystem()
        val root = CoreStorage(fs, "/state".toPath())
        val account = root.scope("first")
        val machine =
            Machine.from(
                Daemon(
                    id = "studio",
                    name = "Studio",
                    online = true,
                    compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE,
                ),
                Instant.parse("2026-10-01T12:00:00Z"),
            )
        DirectoryCache.write(account, listOf(machine), SilentLogger)
        val cached = DirectoryCache.read(account, SilentLogger)
        assertTrue(cached.all.single().serverOnline)
        assertEquals("Studio", cached.all.single().name)
        assertFalse(cached.confirmed)
        assertTrue(cached.online.isEmpty())
        assertTrue(MachineChoice.ordered(cached, emptyMap()).isEmpty())
        assertTrue(DirectoryCache.read(root.scope("second"), SilentLogger).all.isEmpty())
        DirectoryCache.write(account, emptyList(), SilentLogger)
        assertTrue(
            DirectoryCache.read(account, SilentLogger).all.isEmpty(),
            "a fresh empty directory removes cached machines",
        )
    }
}
