package com.getdieter.core.client

import com.getdieter.api.v1.MailFolder
import com.getdieter.client.v1.MailCommand
import com.getdieter.client.v1.MailSlice
import com.getdieter.client.v1.NotificationResponse
import com.getdieter.client.v1.NotificationTarget
import com.getdieter.client.v1.Result
import com.getdieter.client.v1.Step
import com.getdieter.core.CoreRuntime
import com.getdieter.core.board.Lanes
import com.getdieter.core.connection.ConnectionPhase
import com.getdieter.core.connection.MachineSyncs
import com.getdieter.core.mail.MailContext
import com.getdieter.core.mail.MailRules
import com.getdieter.core.mail.MailSurface
import com.getdieter.core.mail.MailView
import com.getdieter.core.navigation.OpenRequests
import com.getdieter.core.notifications.NotificationResponses
import com.getdieter.core.notifications.NotificationRoute
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.runtime.localUtcOffsetSeconds
import com.getdieter.core.v1.OutboxState
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map

// The mail surface (SLICE_MAIL), its commands, and where notification responses lead.

/** [view]'s mail slice from the runtime's state now; a body it shows starts loading. */
internal fun CoreRuntime.mailSlice(view: MailView): MailSlice {
    val projection = mailProjection()
    // Agent names come from the senders' machines' catalogs.
    for (machine in projection.machines.values) if (machine.reachable) metadata.ensure(machine.id)
    val selected = view.selected?.let(projection::item)
    val phase = connection.state.value.phase
    val failed =
        outbox.view.value.entries.lastOrNull {
            MailRules.changesMail(it) && it.state == OutboxState.OUTBOX_STATE_FAILED
        }
    return MailRules.slice(
        MailContext(
            mailbox = projection,
            view = view,
            preferences = mailbox.preferences.value,
            body = selected?.let { mailbox.body(it, projection.machine(it.machineId)) },
            liveCards =
                setOfNotNull(
                    selected?.header?.sender?.card_id?.takeIf {
                        it.isNotEmpty() && workspace.state.value.card(it) != null
                    }
                ),
            now = platform.clock.now(),
            offset = ::localUtcOffsetSeconds,
            harnesses = { loadedCatalog(it).orEmpty() },
            loading =
                !accountSync.loaded.value &&
                    phase in
                        setOf(
                            ConnectionPhase.CONNECTING,
                            ConnectionPhase.RECONNECTING,
                            ConnectionPhase.CONNECTED,
                        ),
            failure =
                failed?.let {
                    "${machineName(it.daemon_id)}: ${it.last_error.ifEmpty { "the change failed." }}"
                },
        )
    )
}

/**
 * [surface]'s slices: again whenever its view, a machine's mail, this device's mail changes or kept
 * bodies, the machines' sync state, the conversations, the agent catalogs, or the minute (for time
 * labels) change.
 */
internal fun CoreRuntime.mailSlices(surface: MailSurface): Flow<MailSlice> {
    val minutes = flow {
        while (true) {
            emit(Unit)
            val now = platform.clock.now().toEpochMilliseconds()
            delay(MINUTE - now % MINUTE)
        }
    }
    return combine(
            listOf(
                surface.view,
                accountSync.snapshot.map { it.mail }.distinctUntilChanged(),
                accountSync.loaded,
                outbox.view
                    .map { view -> view.entries.filter(MailRules::changesMail) }
                    .distinctUntilChanged(),
                mailbox.revision,
                mailbox.preferences,
                connection.syncs,
                connection.state.map { it.phase }.distinctUntilChanged(),
                connection.session.map { it != null }.distinctUntilChanged(),
                reachabilityChanges(),
                workspace.state
                    .map { view -> view.allItems.mapTo(HashSet()) { it.id } }
                    .distinctUntilChanged(),
                metadata.machines,
                minutes,
            )
        ) {
            mailSlice(surface.view.value)
        }
        .distinctUntilChanged()
}

private const val MINUTE = 60_000L

/**
 * A mail command. Preferences need no surface; everything else needs the view's mail surface (the
 * unscoped one for an empty scope).
 */
internal fun CoreRuntime.executeMail(
    command: MailCommand,
    surfaces: Surfaces<MailSurface>,
): Result {
    command.set_preferences?.let {
        mailbox.setPreferences(it)
        return Result(mail = mailSlice(surfaces[command.scope]?.view?.value ?: MailView()))
    }
    val surface = surfaces.scoped(command.scope, "Open the mail first.")
    val box = command.select_box
    val select = command.select
    val search = command.search
    val filter = command.filter
    val change = command.change
    val delete = command.delete
    val active = command.active
    when {
        box != null -> surface.selectBox(box)
        select != null -> surface.select(select)
        search != null -> surface.search(search)
        filter != null -> surface.filter(filter)
        change != null -> {
            if (change.refs.isEmpty()) invalid("Choose the messages to change.")
            if (
                change.read == null &&
                    change.flagged == null &&
                    change.folder == MailFolder.MAIL_FOLDER_UNSPECIFIED
            )
                invalid("Choose what to change.")
            surface.change(change.refs, change.read, change.flagged, change.folder)
        }
        delete != null -> {
            if (delete.refs.isEmpty()) invalid("Choose the messages to delete.")
            surface.delete(delete.refs)
        }
        command.empty_trash != null -> surface.emptyTrash()
        command.mark_all_read != null ->
            surface.markAllRead(
                MailRules.listed(mailProjection(), surface.view.value)
                    .filter { !it.header.read }
                    .map { it.ref }
            )
        active != null -> surface.setActive(active.on)
        else -> invalid("Choose what to do with the mail.")
    }
    return Result(mail = mailSlice(surface.view.value))
}

/**
 * Where a notification [response] leads ([NotificationResponses.route]). A mail notification's
 * actions change the message in place, and a tap opens it, selected in the unscoped mail surface. A
 * conversation's opens it while the account shows it (or may still), else the Inbox; Mark done
 * finishes a card ready for review.
 */
internal suspend fun CoreRuntime.respond(
    response: NotificationResponse,
    surfaces: Surfaces<MailSurface>,
): Result {
    val route =
        NotificationResponses.route(
            response.key,
            response.action,
            open = { cardId ->
                val view = workspace.state.value
                OpenRequests.resolve(
                    outbox.view.value.resolve(cardId),
                    view.allItems,
                    inInbox = false,
                    loading = !view.loaded,
                    phase = connection.state.value.phase,
                    catchingUp =
                        !MachineSyncs.current(connection.machines.value, connection.syncs.value),
                )
            },
            canFinish = { card ->
                OutboxPolicy.isServerBacked(card.id) &&
                    Lanes.done(workspace.directoryProjection.board(card.board_id)) != null
            },
        )
    val none = NotificationTarget(none = Step())
    val target =
        when (route) {
            is NotificationRoute.ChangeMail -> {
                mailbox.change(listOf(route.ref), route.read, folder = route.folder)
                none
            }
            is NotificationRoute.OpenMail -> {
                surfaces.unscoped().select(route.ref)
                NotificationTarget(mail = route.ref)
            }
            is NotificationRoute.FinishCard -> {
                board.finish(route.cardId)
                none
            }
            is NotificationRoute.OpenConversation -> NotificationTarget(card_id = route.cardId)
            NotificationRoute.Inbox -> NotificationTarget(inbox = Step())
            NotificationRoute.None -> none
        }
    return Result(notification_target = target)
}
