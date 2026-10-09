package com.dbpprt.dieter.mobile

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon as MaterialIcon
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.mobile.icons.*

/**
 * Every icon used by the shared screens. iOS draws the named SF Symbol through UIKit, so weights,
 * optical sizes and new symbol shapes match the system; Android and the JVM draw Material icons.
 */
internal enum class Glyph(val symbol: String, private val material: () -> ImageVector) {
    INBOX("tray", { Icons.Outlined.Inbox }),
    PROJECTS("folder", { Icons.Outlined.Folder }),
    BOARD("rectangle.split.3x1", { Icons.Outlined.ViewKanban }),
    CHATS("bubble.left.and.bubble.right", { Icons.Outlined.Forum }),
    CHAT("bubble.left", { Icons.Outlined.ChatBubbleOutline }),
    TOOLS("square.grid.2x2", { Icons.Outlined.GridView }),
    COMPOSE("square.and.pencil", { Icons.Outlined.Edit }),
    ADD("plus", { Icons.Outlined.Add }),
    SEARCH("magnifyingglass", { Icons.Outlined.Search }),
    FILTER("line.3.horizontal.decrease", { Icons.Outlined.FilterList }),
    MORE("ellipsis", { Icons.Outlined.MoreVert }),
    MORE_HORIZONTAL("ellipsis", { Icons.Outlined.MoreHoriz }),
    BACK("chevron.backward", { Icons.AutoMirrored.Outlined.ArrowBack }),
    CHEVRON_RIGHT("chevron.forward", { Icons.Outlined.ChevronRight }),
    CHEVRON_DOWN("chevron.down", { Icons.Outlined.ExpandMore }),
    CHEVRON_UP_DOWN("chevron.up.chevron.down", { Icons.Outlined.ExpandMore }),
    CLOSE("xmark", { Icons.Outlined.Close }),
    CHECK("checkmark", { Icons.Outlined.Check }),
    CHECK_CIRCLE("checkmark.circle.fill", { Icons.Outlined.CheckCircle }),
    TASK_DONE("checkmark.circle", { Icons.Outlined.TaskAlt }),
    CIRCLE("circle", { Icons.Outlined.RadioButtonUnchecked }),
    CIRCLE_FILL("circle.fill", { Icons.Outlined.Circle }),
    SETTINGS("gearshape", { Icons.Outlined.Settings }),
    MACHINE("laptopcomputer", { Icons.Outlined.Computer }),
    PHONE("iphone", { Icons.Outlined.Smartphone }),
    SERVER("server.rack", { Icons.Outlined.Dns }),
    TERMINAL("apple.terminal", { Icons.Outlined.Terminal }),
    SCREENS("display", { Icons.Outlined.DesktopWindows }),
    FILE("doc.text", { Icons.Outlined.Description }),
    FILE_PLAIN("doc", { Icons.Outlined.InsertDriveFile }),
    FOLDER("folder", { Icons.Outlined.Folder }),
    FOLDER_OPEN("folder", { Icons.Outlined.FolderOpen }),
    FOLDER_ADD("folder.badge.plus", { Icons.Outlined.CreateNewFolder }),
    SCHEDULES("calendar.badge.clock", { Icons.Outlined.CalendarMonth }),
    CLOCK("clock", { Icons.Outlined.Schedule }),
    USAGE("gauge.with.dots.needle.33percent", { Icons.Outlined.Speed }),
    CHANGES("plus.forwardslash.minus", { Icons.Outlined.Difference }),
    BRANCH("arrow.triangle.branch", { Icons.Outlined.AccountTree }),
    FORK("arrow.triangle.branch", { Icons.Outlined.CallSplit }),
    MERGE("arrow.triangle.merge", { Icons.Outlined.Merge }),
    COMMIT("smallcircle.filled.circle", { Icons.Outlined.Commit }),
    PUSH("arrow.up.circle", { Icons.Outlined.Upload }),
    PULL("arrow.down.circle", { Icons.Outlined.Download }),
    ARCHIVE("archivebox", { Icons.Outlined.Archive }),
    UNARCHIVE("arrow.up.bin", { Icons.Outlined.Unarchive }),
    REFRESH("arrow.clockwise", { Icons.Outlined.Refresh }),
    SYNC("arrow.triangle.2.circlepath", { Icons.Outlined.Sync }),
    PLAY("play.fill", { Icons.Outlined.PlayArrow }),
    PAUSE("pause.fill", { Icons.Outlined.Pause }),
    STOP("stop.fill", { Icons.Outlined.Stop }),
    SEND("arrow.up", { Icons.AutoMirrored.Outlined.Send }),
    ARROW_UP("arrow.up", { Icons.Outlined.ArrowUpward }),
    ARROW_DOWN("arrow.down", { Icons.Outlined.ArrowDownward }),
    ATTACH("paperclip", { Icons.Outlined.AttachFile }),
    COPY("doc.on.doc", { Icons.Outlined.ContentCopy }),
    PASTE("doc.on.clipboard", { Icons.Outlined.ContentPaste }),
    EDIT("pencil", { Icons.Outlined.Edit }),
    RENAME("pencil.line", { Icons.Outlined.DriveFileRenameOutline }),
    MOVE("arrow.left.arrow.right", { Icons.Outlined.SwapHoriz }),
    LABEL("tag", { Icons.Outlined.Label }),
    TRASH("trash", { Icons.Outlined.Delete }),
    PIN("pin", { Icons.Outlined.PushPin }),
    HISTORY("clock.arrow.circlepath", { Icons.Outlined.History }),
    TIMELINE("chart.bar.xaxis", { Icons.Outlined.Timeline }),
    SUBAGENTS("person.2", { Icons.Outlined.Group }),
    PROCESSES("gearshape.2", { Icons.Outlined.Memory }),
    EYE("eye", { Icons.Outlined.Visibility }),
    EYE_SLASH("eye.slash", { Icons.Outlined.VisibilityOff }),
    KEYBOARD("keyboard", { Icons.Outlined.Keyboard }),
    KEYBOARD_HIDE("keyboard.chevron.compact.down", { Icons.Outlined.KeyboardHide }),
    RETURN("return", { Icons.Outlined.KeyboardReturn }),
    SORT("arrow.up.arrow.down", { Icons.Outlined.Sort }),
    WARNING("exclamationmark.triangle", { Icons.Outlined.WarningAmber }),
    ERROR("exclamationmark.circle", { Icons.Outlined.ErrorOutline }),
    INFO("info.circle", { Icons.Outlined.Info }),
    PERSON("person.crop.circle", { Icons.Outlined.AccountCircle }),
    SIGN_OUT("rectangle.portrait.and.arrow.right", { Icons.Outlined.Logout }),
    PALETTE("paintpalette", { Icons.Outlined.Palette }),
    APPEARANCE("circle.lefthalf.filled", { Icons.Outlined.Brightness6 }),
    MOON("moon", { Icons.Outlined.DarkMode }),
    SUN("sun.max", { Icons.Outlined.LightMode }),
    BOLT("bolt", { Icons.Outlined.Bolt }),
    SPARKLES("sparkles", { Icons.Outlined.AutoAwesome }),
    BRAIN("brain", { Icons.Outlined.AutoAwesome }),
    CPU("cpu", { Icons.Outlined.Memory }),
    LINK("link", { Icons.Outlined.Link }),
    OPEN("arrow.up.right.square", { Icons.Outlined.OpenInNew }),
    GLOBE("globe", { Icons.Outlined.Language }),
    LOCK("lock", { Icons.Outlined.Lock }),
    KEY("key", { Icons.Outlined.Key }),
    STAR("star", { Icons.Outlined.Star }),
    CODE("chevron.left.forwardslash.chevron.right", { Icons.Outlined.Code }),
    DOC_TEXT("doc.plaintext", { Icons.Outlined.Article }),
    CHECKLIST("checklist", { Icons.Outlined.Checklist }),
    MOUSE("cursorarrow", { Icons.Outlined.Mouse }),
    ZOOM_IN("plus.magnifyingglass", { Icons.Outlined.ZoomIn }),
    ZOOM_OUT("minus.magnifyingglass", { Icons.Outlined.ZoomOut }),
    FIT("arrow.up.left.and.arrow.down.right", { Icons.Outlined.FitScreen }),
    IMAGE("photo", { Icons.Outlined.Image }),
    UNDO("arrow.uturn.backward", { Icons.Outlined.Undo }),
    HOURGLASS("hourglass", { Icons.Outlined.HourglassEmpty }),
    OFFLINE("icloud.slash", { Icons.Outlined.CloudOff }),
    BELL("bell", { Icons.Outlined.NotificationsNone }),
    WAND("wand.and.stars", { Icons.Outlined.Tune }),
    LIST("list.bullet", { Icons.Outlined.ViewAgenda }),
    TAG("number", { Icons.Outlined.Tag }),
    QUEUE("text.badge.plus", { Icons.Outlined.PlaylistAdd }),
    CANCEL("xmark.circle", { Icons.Outlined.Cancel }),
    PLAY_CIRCLE("play.circle", { Icons.Outlined.PlayArrow }),
    BADGE("person.text.rectangle", { Icons.Outlined.Badge });

    val vector: ImageVector
        get() = material()
}

/** Symbol weights map to UIImage.SymbolWeight on iOS. Android ignores them. */
internal enum class GlyphWeight {
    LIGHT,
    REGULAR,
    MEDIUM,
    SEMIBOLD,
    BOLD,
}

/** An SF Symbol painter on iOS. Null where Material vectors are used. */
@Composable
internal expect fun platformSymbolPainter(symbol: String, size: Dp, weight: GlyphWeight): Painter?

@Composable
internal fun Icon(
    glyph: Glyph,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    tint: Color = LocalContentColor.current,
    size: Dp = 22.dp,
    weight: GlyphWeight = GlyphWeight.REGULAR,
) {
    val symbol = platformSymbolPainter(glyph.symbol, size, weight)
    if (symbol != null)
        Box(modifier.size(size), contentAlignment = Alignment.Center) {
            MaterialIcon(symbol, contentDescription, tint = tint)
        }
    else MaterialIcon(glyph.vector, contentDescription, modifier.size(size), tint = tint)
}
