package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.api.gateway.v1.Daemon
import com.dbpprt.dieter.api.gateway.v1.ListDaemonsResponse
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.time.Instant

/** Last reported presence is display-only until the gateway confirms the directory. */
internal object DirectoryCache {
    private const val FILE = "machines.pb"

    fun read(storage: CoreStorage, logger: CoreLogger): MachineDirectory = runCatching {
        val daemons =
            storage.read(FILE)?.let(ListDaemonsResponse.ADAPTER::decode)?.daemons.orEmpty()
        MachineDirectory(daemons.map { Machine.from(it, Instant.DISTANT_PAST) }, confirmed = false)
    }
        .onFailure { logger.warn("DirectoryCache", "could not read cached machines", it) }
        .getOrDefault(MachineDirectory(confirmed = false))

    fun write(storage: CoreStorage, machines: List<Machine>, logger: CoreLogger) {
        runCatching {
            storage.write(
                FILE,
                ListDaemonsResponse.ADAPTER.encode(
                    ListDaemonsResponse(
                        daemons =
                            machines.map {
                                Daemon(
                                    id = it.id,
                                    name = it.name,
                                    online = it.serverOnline,
                                    last_seen_at = it.lastSeenAt,
                                    release_version = it.releaseVersion,
                                    minimum_release_version = it.minimumReleaseVersion,
                                    compatibility = it.compatibility,
                                    generation = it.generation,
                                    remote_desktop = it.remoteDesktop,
                                )
                            }
                    )
                ),
            )
        }
            .onFailure { logger.warn("DirectoryCache", "could not cache machines", it) }
    }
}
