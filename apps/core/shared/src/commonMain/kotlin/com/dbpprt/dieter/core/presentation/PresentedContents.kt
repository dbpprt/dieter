package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.ContentPresentation
import com.dbpprt.dieter.client.v1.PresentedContentView
import com.dbpprt.dieter.core.files.FilePaths

/**
 * What the agent presented in a conversation (`Conversation.presented_content`), as clients without
 * a workspace pane offer it: a chip that opens the page in the browser, or the file in the
 * workspace's file viewer. The daemon validated it; this keeps only an HTTP(S) page or a relative
 * workspace path.
 */
object PresentedContents {
    private const val MAX_TITLE = 120

    fun view(value: ContentPresentation?): PresentedContentView? {
        value ?: return null
        val url = value.url.trim()
        val path = value.path.trim()
        val title = value.title.trim().take(MAX_TITLE)
        if (url.isNotEmpty()) {
            val scheme = url.substringBefore("://", "").lowercase()
            val rest = url.substringAfter("://", "")
            val host =
                rest
                    .substringBefore('/')
                    .substringBefore('?')
                    .substringBefore('#')
                    .substringAfterLast('@')
                    .lowercase()
            if (
                (scheme != "https" && scheme != "http") ||
                    host.isEmpty() ||
                    '@' in rest.substringBefore('/')
            )
                return null
            val design = BrowserRules.isClaudeDesign(url)
            val artifact = BrowserRules.isClaudeArtifact(url)
            return PresentedContentView(
                id = value.id,
                title =
                    title.ifEmpty {
                        when {
                            artifact -> "Claude artifact"
                            design -> "Claude Design project"
                            else -> host
                        }
                    },
                subtitle =
                    when {
                        artifact -> "Claude artifact"
                        design -> "claude.ai/design"
                        else -> host
                    },
                url = url,
                system_browser = BrowserRules.systemBrowserNotice(url) != null,
                claude_design = design,
            )
        }
        val normalized =
            FilePaths.normalize(path).getOrNull()?.takeIf { it.isNotEmpty() } ?: return null
        val line = value.line.coerceAtLeast(0)
        return PresentedContentView(
            id = value.id,
            title = title.ifEmpty { normalized.substringAfterLast('/') },
            subtitle = if (line > 0) "$normalized · line $line" else normalized,
            path = normalized,
            line = line,
        )
    }
}
