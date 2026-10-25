package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Agent channels (experimental) as the core presents them: the account's project channels with
 * their unread count, the open channel's stream, and the account's switch. The core lists, watches
 * and words everything; this holder folds its slices and sends its commands.
 */
class ChannelsModel internal constructor(private val context: StoreContext) {
    val slice = MutableStateFlow(ChannelsSlice())
    val settings = MutableStateFlow(ChannelSettingsSlice())
    private var shown: String? = null
    private var active = false

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_CHANNELS, MobileStore.CHANNELS_SCOPE) {
            it.channels?.let { value -> slice.value = value }
        }
        context.observeAlways(Slice.SLICE_CHANNEL_SETTINGS, "") {
            it.channel_settings?.let { value -> settings.value = value }
        }
    }

    /**
     * [projectId]'s stream is on screen and watched; null shows the list only, which then lists
     * slowly for the badge.
     */
    internal fun show(projectId: String?) {
        // The core drops its selection while every setting is off, so select again whenever
        // its stream is not the open channel's.
        if (
            projectId != null &&
                (projectId != shown || slice.value.stream?.channel?.project_id != projectId)
        ) {
            shown = projectId
            send(ChannelsCommand(select = ChannelRef(projectId)))
        }
        val on = projectId != null
        if (on != active) {
            active = on
            send(ChannelsCommand(active = Toggle(on)))
        }
    }

    fun refresh() = send(ChannelsCommand(refresh = Step()))

    /**
     * Posts [body] as the user to everyone, @here or [to]; [posted] runs once the channel took it.
     * A refusal shows in the stream.
     */
    fun post(
        body: String,
        to: List<String>,
        here: Boolean,
        kind: ChannelMessageKind,
        wake: Boolean,
        posted: () -> Unit,
    ) =
        send(
            ChannelsCommand(
                post =
                    ChannelPost(
                        body = body,
                        to_card_ids = if (here) emptyList() else to,
                        here = here,
                        kind = kind,
                        wake = wake && !here && to.isNotEmpty(),
                    )
            ),
            quiet = true,
            done = posted,
        )

    fun pin(messageId: String, pinned: Boolean) =
        send(ChannelsCommand(pin = ChannelPin(messageId, pinned)), quiet = true)

    fun release(cardId: String, path: String) =
        send(ChannelsCommand(release_claim = ChannelClaimRelease(cardId, path)), quiet = true)

    /** The open channel's newest message is visible. */
    fun markRead() {
        if ((slice.value.stream?.unread ?: 0) > 0) send(ChannelsCommand(mark_read = Step()))
    }

    /** The account-wide switch, saved on a reachable machine. */
    fun setEnabled(on: Boolean) =
        context.command(
            Command(
                channels =
                    ChannelsCommand(
                        set_setting =
                            ChannelSettingChange(
                                ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL,
                                mode =
                                    if (on) ChannelSettingMode.CHANNEL_SETTING_MODE_ON
                                    else ChannelSettingMode.CHANNEL_SETTING_MODE_OFF,
                            )
                    )
            )
        )

    /**
     * Sends [command] for the channels scope and folds the slice it returns. A [quiet] failure
     * shows only where the stream says why (its action error).
     */
    private fun send(command: ChannelsCommand, quiet: Boolean = false, done: () -> Unit = {}) {
        if (context.closed) return
        context.scope.launch {
            try {
                val result = context.serialized {
                    context.core.dispatch(
                        Command(channels = command.copy(scope = MobileStore.CHANNELS_SCOPE))
                    )
                }
                result.channels?.let { slice.value = it }
                done()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                if (!quiet) context.error.value = failure.message ?: "The channel command failed."
            }
        }
    }
}
