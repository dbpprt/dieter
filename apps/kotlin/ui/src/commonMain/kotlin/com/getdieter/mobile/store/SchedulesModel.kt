package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.flow.MutableStateFlow

/** A project's schedules. */
class SchedulesModel internal constructor(private val context: StoreContext) {
    val slice = MutableStateFlow(SchedulesSlice())

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_SCHEDULES, MobileStore.SCHEDULES_SCOPE) {
            it.schedules?.let { value -> slice.value = value }
        }
    }

    /** Binds Schedules to [projectId], then loads them. */
    internal fun load(projectId: String) = context.action {
        context.core.dispatch(
            Command(
                schedules =
                    SchedulesCommand(
                        scope = MobileStore.SCHEDULES_SCOPE,
                        bind = ScheduleProject(projectId),
                    )
            )
        )
        context.core.dispatch(
            Command(
                schedules = SchedulesCommand(scope = MobileStore.SCHEDULES_SCOPE, load = Step())
            )
        )
    }
}
