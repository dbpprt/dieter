package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.client.v1.ChatDestination
import com.dbpprt.dieter.client.v1.ChatDestinationGroup
import com.dbpprt.dieter.client.v1.ChatDestinationMachine
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.presentation.DisplayPaths

/** Where a new chat can run: every attached checkout, grouped by the machine that holds it. */
object ChatDestinations {
    /** [projects]' attached checkouts on [machines]; online machines first, then by name. */
    fun groups(projects: List<Project>, machines: List<ChatDestinationMachine>): List<ChatDestinationGroup> {
        val byDaemon = machines.associateBy { it.daemon_id }
        data class Entry(val project: Project, val checkoutId: String, val path: String, val machine: ChatDestinationMachine)
        val entries = projects.flatMap { project ->
            Creation.choices(project).map { checkout ->
                val machine = byDaemon[checkout.daemon_id]
                    ?: ChatDestinationMachine(daemon_id = checkout.daemon_id, id = "unavailable:${checkout.daemon_id}", name = checkout.daemon_id)
                Entry(project, checkout.id, checkout.path, machine)
            }
        }
        return entries.groupBy { it.machine.id }.values.map { values ->
            val machine = values.first().machine
            val presence = MachineRows.presence(machine.online)
            val sorted = values.sortedWith(
                compareBy<Entry, String>(String.CASE_INSENSITIVE_ORDER) { it.project.name }
                    .thenBy(String.CASE_INSENSITIVE_ORDER) { it.path.ifEmpty { it.checkoutId } }
                    .thenBy { it.project.id },
            )
            ChatDestinationGroup(
                machine_id = machine.id, machine_name = machine.name, machine_online = machine.online, machine_version = machine.version,
                title = "${machine.name} · $presence",
                destinations = sorted.map { entry ->
                    val path = DisplayPaths.compact(entry.path)
                    val siblings = sorted.count { it.project.id == entry.project.id }
                    ChatDestination(
                        project_id = entry.project.id, checkout_id = entry.checkoutId, machine_id = machine.id,
                        title = "${entry.project.name} · ${machine.name}",
                        detail = if (path.isEmpty()) presence else "$presence · $path",
                        option_title = if (siblings > 1) optionTitle(entry.project, entry.checkoutId) else entry.project.name,
                    )
                },
            )
        }.sortedWith(
            compareByDescending<ChatDestinationGroup> { it.machine_online }
                .thenBy(String.CASE_INSENSITIVE_ORDER) { it.machine_name }
                .thenBy { it.machine_id },
        )
    }

    /**
     * The destination to show first: the [checkoutId] one in [projectId]
     * (when given), else [projectId] on [machineId], else that machine's
     * first, else [projectId] anywhere, else the first of all.
     */
    fun preferred(groups: List<ChatDestinationGroup>, machineId: String, projectId: String, checkoutId: String): ChatDestination? {
        val all = groups.flatMap { it.destinations }
        if (checkoutId.isNotEmpty()) {
            all.firstOrNull { it.checkout_id == checkoutId && (projectId.isEmpty() || it.project_id == projectId) }?.let { return it }
        }
        groups.firstOrNull { it.machine_id == machineId }?.let { machine ->
            if (projectId.isNotEmpty()) machine.destinations.firstOrNull { it.project_id == projectId }?.let { return it }
            machine.destinations.firstOrNull()?.let { return it }
        }
        if (projectId.isNotEmpty()) all.firstOrNull { it.project_id == projectId }?.let { return it }
        return all.firstOrNull()
    }

    private fun optionTitle(project: Project, checkoutId: String): String {
        val checkout = project.checkouts.firstOrNull { it.id == checkoutId }
        val name = checkout?.name?.trim().orEmpty()
        if (name.isNotEmpty()) return "${project.name} · $name"
        val folder = checkout?.path.orEmpty().trimEnd('/').substringAfterLast('/')
        return if (folder.isEmpty()) project.name else "${project.name} · $folder"
    }
}
