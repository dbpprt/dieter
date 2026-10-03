package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.ContentFileLink
import com.dbpprt.dieter.client.v1.ContentLinkFailure
import com.dbpprt.dieter.client.v1.ContentLinkResolution
import com.dbpprt.dieter.client.v1.DetectedLink
import com.dbpprt.dieter.client.v1.DetectedLinks as DetectedLinkList
import com.dbpprt.dieter.core.presentation.BrowserRules
import com.dbpprt.dieter.core.presentation.ContentLink
import com.dbpprt.dieter.core.presentation.ContentLinks
import com.dbpprt.dieter.core.presentation.DetectedLinks
import com.dbpprt.dieter.core.presentation.LinkError
import com.dbpprt.dieter.core.presentation.LinkException
import com.dbpprt.dieter.core.presentation.WorkspaceImages

/** Links in conversations and the workspace browser's rules, as views call them while rendering or opening a link. */
object LinkExports {
    /**
     * Where a link leads: a workspace file (path relative to [workspaceRoot],
     * line and end line or 0), a web URL, or why it cannot open. Empty
     * [workspaceRoot] or [relativeTo] means none.
     */
    fun resolveContentLink(url: String, workspaceRoot: String, relativeTo: String): ContentLinkResolution = try {
        when (val link = ContentLinks.resolve(url, workspaceRoot.ifEmpty { null }, relativeTo.ifEmpty { null })) {
            is ContentLink.File -> ContentLinkResolution(file_ = ContentFileLink(path = link.path, line = link.line ?: 0))
            is ContentLink.Web -> ContentLinkResolution(web_url = link.url)
        }
    } catch (failure: LinkException) {
        ContentLinkResolution(failure = ContentLinkFailure(kind = kind(failure.error), message = ContentLinks.message(failure.error, failure.scheme)))
    }

    /** The web links in prose [text], in order, with UTF-16 ranges. */
    fun detectLinks(text: String): DetectedLinkList =
        DetectedLinkList(links = DetectedLinks.find(text).map { DetectedLink(start = it.range.first, length = it.range.last + 1 - it.range.first, url = it.url) })

    /**
     * Whether a conversation's image [destination] may be a workspace file:
     * a relative, absolute, or `file://` image path. Opening it through the
     * files surface resolves it against the card's workspace.
     */
    fun isWorkspaceImage(destination: String): Boolean = WorkspaceImages.isWorkspaceImage(destination)

    /** Whether the workspace browser hands an http(s) [url] to the system browser under the user's [rules]. */
    fun externalBrowserRuleMatches(url: String, rules: List<String>): Boolean = BrowserRules.matches(url, rules)

    /** The rule to store for what the user typed; "" when it is not a valid host or HTTP(S) URL. */
    fun normalizeExternalBrowserRule(input: String): String = BrowserRules.normalized(input).orEmpty()

    /** Whether a browser address's host is this machine, which a remote conversation's browser may not open. */
    fun isLoopbackBrowserHost(host: String): Boolean = BrowserRules.isLoopbackHost(host)

    private fun kind(error: LinkError): ContentLinkFailure.Kind = when (error) {
        LinkError.INVALID_WEB_URL -> ContentLinkFailure.Kind.KIND_INVALID_WEB_URL
        LinkError.UNSUPPORTED_FILE_HOST -> ContentLinkFailure.Kind.KIND_UNSUPPORTED_FILE_HOST
        LinkError.UNSUPPORTED_SCHEME -> ContentLinkFailure.Kind.KIND_UNSUPPORTED_SCHEME
        LinkError.INVALID_LINE -> ContentLinkFailure.Kind.KIND_INVALID_LINE
        LinkError.INVALID_LINK -> ContentLinkFailure.Kind.KIND_INVALID_LINK
        LinkError.INVALID_WORKSPACE -> ContentLinkFailure.Kind.KIND_INVALID_WORKSPACE
        LinkError.OUTSIDE_WORKSPACE -> ContentLinkFailure.Kind.KIND_OUTSIDE_WORKSPACE
    }
}
