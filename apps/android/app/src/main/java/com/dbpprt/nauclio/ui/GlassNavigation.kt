package com.dbpprt.nauclio.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.dbpprt.nauclio.connection.isActiveRuntime
import com.dbpprt.nauclio.ui.theme.NauclioAegean
import com.dbpprt.nauclio.ui.theme.NauclioCobalt
import com.dbpprt.nauclio.ui.theme.NauclioMuted
import com.dbpprt.nauclio.ui.theme.NauclioOutline
import com.dbpprt.nauclio.ui.theme.NauclioText
import com.dbpprt.nauclio.ui.theme.NauclioPrimary
import com.dbpprt.nauclio.ui.theme.NauclioAbyss

internal val GlassFadeSoft = Color(0x6616151D)
internal val GlassFadeStrong = Color(0xCC0D0C12)
internal val GlassDockFill = Color(0xE6181722)

private data class GlassDestination(val destination: Destination, val label: String, val icon: ImageVector)

private val glassDestinations = listOf(
    GlassDestination(Destination.CHATS, "Chats", Icons.Outlined.ChatBubbleOutline),
    GlassDestination(Destination.BOARD, "Boards", Icons.Outlined.ViewKanban),
    GlassDestination(Destination.TERMINALS, "Terminal", Icons.Outlined.Terminal),
    GlassDestination(Destination.FILES, "Files", Icons.Outlined.FolderOpen),
    GlassDestination(Destination.SCHEDULES, "Schedules", Icons.Outlined.CalendarMonth),
)

@Composable
fun GlassNavigationDock(
    state: NauclioUiState,
    onNavigate: (Destination) -> Unit,
    onSettings: () -> Unit,
) {
    val activeChats = state.chats.count { isActiveRuntime(it.runtime) }
    Box(
        Modifier.fillMaxWidth().navigationBarsPadding().height(100.dp).testTag("glass-navigation"),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Box(
            Modifier.fillMaxWidth().height(82.dp)
                .background(
                    Brush.verticalGradient(
                        listOf(Color.Transparent, GlassFadeSoft, GlassFadeStrong),
                    ),
                ),
        )
        Box(Modifier.widthIn(max = 400.dp).fillMaxWidth().height(96.dp), contentAlignment = Alignment.BottomCenter) {
            Surface(
                color = GlassDockFill,
                contentColor = NauclioText,
                shape = RoundedCornerShape(32.dp),
                border = BorderStroke(1.dp, NauclioAegean.copy(alpha = 0.22f)),
                shadowElevation = 14.dp,
                modifier = Modifier.fillMaxWidth().padding(start = 12.dp, top = 22.dp, end = 12.dp, bottom = 4.dp)
                    .height(70.dp),
            ) {}
            Row(
                Modifier.fillMaxSize().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                glassDestinations.forEachIndexed { index, item ->
                    GlassDockItem(
                        item = item,
                        selected = state.destination == item.destination,
                        badge = if (index == 0 && activeChats > 0) activeChats else 0,
                        onClick = { onNavigate(item.destination) },
                        modifier = Modifier.weight(1f),
                    )
                }
                Box(
                    Modifier.weight(1f).fillMaxHeight(),
                    contentAlignment = Alignment.BottomCenter,
                ) {
                    Box(
                        Modifier.align(Alignment.BottomStart).padding(bottom = 18.dp).height(42.dp).width(1.dp)
                            .background(NauclioOutline.copy(alpha = 0.7f)),
                    )
                    GlassUtilityButton(
                        onClick = onSettings,
                        icon = Icons.Outlined.Settings,
                        contentDescription = "App settings",
                        testTag = "open-app-settings",
                    )
                }
            }
        }
    }
}

@Composable
private fun GlassUtilityButton(
    onClick: () -> Unit,
    icon: ImageVector,
    contentDescription: String,
    testTag: String,
) {
    Box(
        modifier = Modifier.padding(bottom = 16.dp).size(46.dp).testTag(testTag).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription, tint = NauclioText, modifier = Modifier.size(27.dp))
    }
}

@Composable
private fun GlassDockItem(
    item: GlassDestination,
    selected: Boolean,
    badge: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier.fillMaxHeight()
            .semantics { role = Role.Tab }
            .clickable(onClick = onClick),
        contentAlignment = Alignment.BottomCenter,
    ) {
        if (selected) {
            Box(
                Modifier.align(Alignment.TopCenter).offset(y = (-3).dp).zIndex(2f).size(62.dp)
                    .shadow(16.dp, CircleShape, ambientColor = NauclioCobalt, spotColor = NauclioAegean)
                    .clip(CircleShape)
                    .background(Brush.linearGradient(listOf(NauclioPrimary, NauclioCobalt)))
                    .border(1.dp, Color.White.copy(alpha = 0.46f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(item.icon, null, tint = NauclioAbyss, modifier = Modifier.size(30.dp))
            }
            Text(
                item.label,
                color = NauclioText,
                fontWeight = FontWeight.SemiBold,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Clip,
                modifier = Modifier.padding(bottom = 10.dp),
            )
        } else {
            Box(Modifier.padding(bottom = 17.dp).size(44.dp), contentAlignment = Alignment.Center) {
                Icon(item.icon, item.label, tint = NauclioMuted, modifier = Modifier.size(28.dp))
                if (badge > 0) {
                    Surface(
                        color = NauclioAegean,
                        shape = RoundedCornerShape(50),
                        modifier = Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-3).dp),
                    ) {
                        Text(
                            badge.coerceAtMost(99).toString(),
                            color = NauclioAbyss,
                            fontSize = 9.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(horizontal = 5.dp, vertical = 1.dp),
                        )
                    }
                }
            }
        }
    }
}
