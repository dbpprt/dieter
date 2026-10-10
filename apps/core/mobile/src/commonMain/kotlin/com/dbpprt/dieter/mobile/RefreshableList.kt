@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.layout.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** One refresh gesture and accessibility action for both mobile platforms. */
@Composable
internal fun RefreshableList(
    refreshing: Boolean,
    onRefresh: () -> Unit,
    tag: String,
    topInset: Dp,
    content: @Composable () -> Unit,
) {
    val state = rememberPullToRefreshState()
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = onRefresh,
        state = state,
        modifier =
            Modifier.fillMaxSize().testTag(tag).semantics {
                stateDescription = if (refreshing) "Refreshing" else "Pull to refresh"
                customActions =
                    listOf(
                        CustomAccessibilityAction("Sync again") {
                            onRefresh()
                            true
                        }
                    )
            },
        indicator = {
            val position = Modifier.align(Alignment.TopCenter).padding(top = topInset)
            if (apple)
                PullToRefreshDefaults.IndicatorBox(
                    state = state,
                    isRefreshing = refreshing,
                    modifier = position,
                    containerColor = Color.Transparent,
                    elevation = 0.dp,
                ) {
                    Spinner(
                        Modifier.size(22.dp)
                            .alpha(if (refreshing) 1f else state.distanceFraction.coerceIn(0f, 1f))
                    )
                }
            else
                PullToRefreshDefaults.Indicator(
                    state = state,
                    isRefreshing = refreshing,
                    modifier = position,
                    containerColor = colors.surfaceContainerHigh,
                    color = palette.accent,
                )
        },
    ) {
        content()
    }
}
