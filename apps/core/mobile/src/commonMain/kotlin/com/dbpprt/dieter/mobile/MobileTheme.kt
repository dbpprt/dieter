package com.dbpprt.dieter.mobile

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.mobile.resources.Res
import com.dbpprt.dieter.mobile.resources.sora_variable
import org.jetbrains.compose.resources.Font

/** Exact shipping Android palette, with native system typography on Apple. */
@Composable
internal fun MobileTheme(store: MobileStore, apple: Boolean, content: @Composable () -> Unit) {
    val palette by store.palette.collectAsState()
    val appearance by store.appearance.collectAsState()
    val dark =
        when (appearance) {
            "dark" -> true
            "light" -> false
            else -> isSystemInDarkTheme()
        }
    val tokens = palette.tokens
    val background = Color(if (dark) tokens.darkBackground else tokens.light)
    val surface = if (dark) Color(tokens.darkSurface) else lerp(background, Color.White, .72f)
    val raised =
        if (dark) Color(tokens.darkRaised) else lerp(background, Color(tokens.darkRaised), .07f)
    val text = Color(if (dark) tokens.light else tokens.darkBrand)
    val muted =
        if (dark) lerp(text, Color(tokens.darkBrand), .30f) else lerp(text, background, .34f)
    val primary = Color(if (dark) tokens.shellStart else tokens.shellEnd)
    val scheme = if (dark) darkColorScheme() else lightColorScheme()
    val colors =
        scheme.copy(
            primary = primary,
            onPrimary = Color(if (dark) tokens.darkBrand else tokens.light),
            primaryContainer = raised,
            onPrimaryContainer = text,
            secondary = Color(if (dark) tokens.eyes else tokens.shellEnd),
            onSecondary = Color(if (dark) tokens.darkBrand else tokens.light),
            secondaryContainer = raised,
            onSecondaryContainer = text,
            onTertiary = Color(if (dark) tokens.darkBrand else tokens.light),
            tertiaryContainer = raised,
            onTertiaryContainer = text,
            surfaceTint = primary,
            tertiary = Color(tokens.paneEnd),
            background = background,
            onBackground = text,
            surface = surface,
            onSurface = text,
            surfaceVariant = raised,
            onSurfaceVariant = muted,
            surfaceContainerLowest = background,
            surfaceContainerLow = lerp(background, surface, .46f),
            surfaceContainer = surface,
            surfaceContainerHigh = raised,
            surfaceContainerHighest = lerp(raised, Color(tokens.paneStart), .14f),
            outline = lerp(raised, text, if (dark) .12f else .14f),
            outlineVariant = lerp(surface, text, if (dark) .06f else .08f),
            error = Color(if (dark) 0xFFF1868E else 0xFFBA1A1A),
        )
    val display = if (apple) FontFamily.Default else FontFamily(Font(Res.font.sora_variable))
    val typography =
        Typography(
            headlineLarge =
                TextStyle(
                    fontFamily = display,
                    fontSize = 32.sp,
                    lineHeight = 38.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
            headlineMedium =
                TextStyle(
                    fontFamily = display,
                    fontSize = 28.sp,
                    lineHeight = 34.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
            headlineSmall =
                TextStyle(
                    fontFamily = display,
                    fontSize = 24.sp,
                    lineHeight = 30.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
            titleLarge =
                TextStyle(
                    fontFamily = display,
                    fontSize = 22.sp,
                    lineHeight = 28.sp,
                    fontWeight = FontWeight.Medium,
                ),
            titleMedium =
                TextStyle(
                    fontFamily = display,
                    fontSize = 16.sp,
                    lineHeight = 22.sp,
                    fontWeight = FontWeight.Medium,
                ),
            titleSmall =
                TextStyle(
                    fontFamily = display,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.Medium,
                ),
            bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 24.sp),
            bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
            bodySmall = TextStyle(fontSize = 12.sp, lineHeight = 16.sp),
            labelLarge =
                TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold),
            labelMedium =
                TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium),
            labelSmall =
                TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium),
        )
    CompositionLocalProvider(LocalApplePresentation provides apple) {
        MaterialTheme(
            colors,
            typography = typography,
            shapes =
                Shapes(
                    RoundedCornerShape(10.dp),
                    RoundedCornerShape(14.dp),
                    RoundedCornerShape(16.dp),
                    RoundedCornerShape(24.dp),
                    RoundedCornerShape(32.dp),
                ),
            content = content,
        )
    }
}

internal val colors: ColorScheme
    @Composable get() = MaterialTheme.colorScheme

internal val LocalApplePresentation = staticCompositionLocalOf { false }

/** Native grouped fields on iOS; the shipping outlined Material controls on Android. */
@Composable
internal fun MobileTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: androidx.compose.ui.Modifier = androidx.compose.ui.Modifier,
    enabled: Boolean = true,
    readOnly: Boolean = false,
    textStyle: TextStyle = LocalTextStyle.current,
    label: (@Composable () -> Unit)? = null,
    placeholder: (@Composable () -> Unit)? = null,
    leadingIcon: (@Composable () -> Unit)? = null,
    trailingIcon: (@Composable () -> Unit)? = null,
    supportingText: (@Composable () -> Unit)? = null,
    singleLine: Boolean = false,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    minLines: Int = 1,
    shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(12.dp),
) {
    if (LocalApplePresentation.current)
        TextField(
            value,
            onValueChange,
            modifier,
            enabled = enabled,
            readOnly = readOnly,
            textStyle = textStyle,
            label = label,
            placeholder = placeholder,
            leadingIcon = leadingIcon,
            trailingIcon = trailingIcon,
            supportingText = supportingText,
            singleLine = singleLine,
            maxLines = maxLines,
            minLines = minLines,
            shape = shape,
            colors =
                TextFieldDefaults.colors(
                    focusedContainerColor = colors.surfaceContainerHigh,
                    unfocusedContainerColor = colors.surfaceContainerHigh,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
        )
    else
        OutlinedTextField(
            value,
            onValueChange,
            modifier,
            enabled = enabled,
            readOnly = readOnly,
            textStyle = textStyle,
            label = label,
            placeholder = placeholder,
            leadingIcon = leadingIcon,
            trailingIcon = trailingIcon,
            supportingText = supportingText,
            singleLine = singleLine,
            maxLines = maxLines,
            minLines = minLines,
            shape = shape,
        )
}
