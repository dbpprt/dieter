@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.design

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

@Composable
internal fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    testTag: String = "search-field",
) {
    if (!apple) {
        Row(
            modifier
                .fillMaxWidth()
                .height(52.dp)
                .clip(CircleShape)
                .background(colors.surfaceContainerHigh)
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Glyph.SEARCH, null, tint = colors.onSurfaceVariant, size = 24.dp)
            Spacer(Modifier.width(14.dp))
            Box(Modifier.weight(1f)) {
                if (value.isEmpty())
                    Text(
                        placeholder,
                        style = MaterialTheme.typography.bodyLarge,
                        color = colors.onSurfaceVariant,
                    )
                BasicTextField(
                    value,
                    onValueChange,
                    Modifier.fillMaxWidth().testTag(testTag),
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.onSurface),
                    cursorBrush = SolidColor(colors.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                )
            }
            if (value.isNotEmpty())
                IconButton({ onValueChange("") }, Modifier.size(36.dp)) {
                    Icon(Glyph.CLOSE, "Clear search", size = 20.dp)
                }
        }
        return
    }
    Row(
        modifier
            .fillMaxWidth()
            .height(40.dp)
            .clip(CircleShape)
            .background(palette.fill)
            .padding(start = 12.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Glyph.SEARCH,
            null,
            tint = palette.secondaryLabel,
            size = 17.dp,
            weight = GlyphWeight.MEDIUM,
        )
        Spacer(Modifier.width(7.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty())
                Text(placeholder, style = type.body, color = palette.secondaryLabel, maxLines = 1)
            BasicTextField(
                value,
                onValueChange,
                Modifier.fillMaxWidth().testTag(testTag),
                singleLine = true,
                textStyle = type.body.copy(color = palette.label),
                cursorBrush =
                    SolidColor(
                        palette.accent.takeUnless { it == Color.Black || it == Color.White }
                            ?: palette.info
                    ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            )
        }
        if (value.isNotEmpty())
            Box(
                Modifier.size(28.dp)
                    .clickable(remember { MutableInteractionSource() }, null) { onValueChange("") }
                    .semantics { contentDescription = "Clear search" },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(17.dp).background(palette.tertiaryLabel, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Glyph.CLOSE,
                        null,
                        tint = palette.cell,
                        size = 9.dp,
                        weight = GlyphWeight.BOLD,
                    )
                }
            }
    }
}

/**
 * Text field with platform styling. iOS uses a filled rounded field (labels become the placeholder,
 * with an optional caption above); Android uses the outlined Material field.
 */
@Composable
internal fun MobileTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
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
    shape: Shape = RoundedCornerShape(12.dp),
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    if (!apple) {
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
            shape = RoundedCornerShape(14.dp),
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
        )
        return
    }
    AppleField(modifier, label, placeholder, supportingText) {
        BasicTextField(
            value,
            onValueChange,
            Modifier.fillMaxWidth(),
            enabled = enabled,
            readOnly = readOnly,
            singleLine = singleLine,
            maxLines = maxLines,
            minLines = minLines,
            textStyle = appleFieldStyle(textStyle, enabled),
            cursorBrush = SolidColor(palette.info),
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            decorationBox = { inner ->
                AppleFieldDecoration(
                    value.isEmpty(),
                    singleLine,
                    placeholder ?: label,
                    leadingIcon,
                    trailingIcon,
                    inner,
                )
            },
        )
    }
}

/**
 * [MobileTextField] for a value whose selection the caller sets, e.g. a field that reformats what
 * is typed and keeps the cursor at the end.
 */
@Composable
internal fun MobileTextField(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    textStyle: TextStyle = LocalTextStyle.current,
    label: (@Composable () -> Unit)? = null,
    placeholder: (@Composable () -> Unit)? = null,
    trailingIcon: (@Composable () -> Unit)? = null,
    supportingText: (@Composable () -> Unit)? = null,
    singleLine: Boolean = false,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    if (!apple) {
        OutlinedTextField(
            value,
            onValueChange,
            modifier,
            enabled = enabled,
            textStyle = textStyle,
            label = label,
            placeholder = placeholder,
            trailingIcon = trailingIcon,
            supportingText = supportingText,
            singleLine = singleLine,
            shape = RoundedCornerShape(14.dp),
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
        )
        return
    }
    AppleField(modifier, label, placeholder, supportingText) {
        BasicTextField(
            value,
            onValueChange,
            Modifier.fillMaxWidth(),
            enabled = enabled,
            singleLine = singleLine,
            textStyle = appleFieldStyle(textStyle, enabled),
            cursorBrush = SolidColor(palette.info),
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            decorationBox = { inner ->
                AppleFieldDecoration(
                    value.text.isEmpty(),
                    singleLine,
                    placeholder ?: label,
                    null,
                    trailingIcon,
                    inner,
                )
            },
        )
    }
}

@Composable
private fun appleFieldStyle(textStyle: TextStyle, enabled: Boolean): TextStyle =
    type.body
        .merge(textStyle.copy(color = palette.label))
        .copy(color = if (enabled) palette.label else palette.secondaryLabel)

/** The iOS field's optional caption above (with a placeholder) and supporting text below. */
@Composable
private fun AppleField(
    modifier: Modifier,
    label: (@Composable () -> Unit)?,
    placeholder: (@Composable () -> Unit)?,
    supportingText: (@Composable () -> Unit)?,
    field: @Composable () -> Unit,
) {
    Column(modifier) {
        if (label != null && placeholder != null)
            CompositionLocalProvider(
                LocalTextStyle provides type.footnote,
                LocalContentColor provides palette.secondaryLabel,
            ) {
                Box(Modifier.padding(start = 4.dp, bottom = 6.dp)) { label() }
            }
        field()
        if (supportingText != null)
            CompositionLocalProvider(
                LocalTextStyle provides type.footnote,
                LocalContentColor provides palette.secondaryLabel,
            ) {
                Box(Modifier.padding(start = 4.dp, top = 6.dp)) { supportingText() }
            }
    }
}

/** The filled, rounded iOS field around the text, with its hint while empty. */
@Composable
private fun AppleFieldDecoration(
    empty: Boolean,
    singleLine: Boolean,
    hint: (@Composable () -> Unit)?,
    leadingIcon: (@Composable () -> Unit)?,
    trailingIcon: (@Composable () -> Unit)?,
    inner: @Composable () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(palette.fill)
            .heightIn(min = 44.dp)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = if (singleLine) Alignment.CenterVertically else Alignment.Top,
    ) {
        if (leadingIcon != null) {
            CompositionLocalProvider(LocalContentColor provides palette.secondaryLabel) {
                leadingIcon()
            }
            Spacer(Modifier.width(8.dp))
        }
        Box(Modifier.weight(1f)) {
            if (empty)
                CompositionLocalProvider(
                    LocalTextStyle provides type.body,
                    LocalContentColor provides palette.secondaryLabel,
                ) {
                    hint?.invoke()
                }
            inner()
        }
        if (trailingIcon != null) {
            Spacer(Modifier.width(8.dp))
            CompositionLocalProvider(LocalContentColor provides palette.secondaryLabel) {
                trailingIcon()
            }
        }
    }
}
