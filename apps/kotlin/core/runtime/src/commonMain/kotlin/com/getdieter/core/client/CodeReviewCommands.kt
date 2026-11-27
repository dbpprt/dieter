package com.getdieter.core.client

import com.getdieter.client.v1.CodeReviewCommand
import com.getdieter.client.v1.Result
import com.getdieter.core.CoreRuntime

/**
 * Runs a code reviewer command ([com.getdieter.core.reviews.CodeReviewCalls]): the account's
 * reviewer setting, a conversation's switch, and a review the user starts. The review itself shows
 * as a CODE_REVIEW step of the conversation's timeline.
 */
internal suspend fun CoreRuntime.executeCodeReview(command: CodeReviewCommand): Result {
    command.settings?.let {
        val machine = codeReviews.settingsMachine(it.daemon_id)
        // The settings form's pickers show this machine's catalog.
        metadata.ensure(machine)
        return Result(reviewer_settings = codeReviews.settings(machine))
    }
    command.update_settings?.let { update ->
        val settings = update.settings ?: invalid("Choose the reviewer's settings.")
        return Result(reviewer_settings = codeReviews.updateSettings(update.daemon_id, settings))
    }
    command.set_enabled?.let {
        return Result(card = codeReviews.setEnabled(it.card_id, it.enabled))
    }
    command.start?.let {
        return Result(code_review = codeReviews.start(it.card_id, it.focus, it.depth))
    }
    invalid("Choose what to do with the code reviewer.")
}
