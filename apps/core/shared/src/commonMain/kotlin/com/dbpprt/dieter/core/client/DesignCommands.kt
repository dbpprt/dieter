package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.ClaudeDesignCommand
import com.dbpprt.dieter.client.v1.ClaudeDesignSignIn
import com.dbpprt.dieter.client.v1.ClaudeDesignSlice
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.core.design.ClaudeDesign
import com.dbpprt.dieter.core.design.ClaudeDesignPresentation
import com.dbpprt.dieter.core.design.ClaudeDesignSignInPhase
import com.dbpprt.dieter.core.design.ClaudeDesignView

internal suspend fun ClaudeDesign.execute(command: ClaudeDesignCommand): Result {
    command.select?.let { select(it.daemon_id.ifEmpty { null }) }
    command.refresh?.let { refresh() }
    command.sign_in?.let { signIn() }
    command.cancel_sign_in?.let { cancelSignIn() }
    command.submit_code?.let { submitCode(it.code) }
    command.set_access?.let { setAccess(it.enabled, it.revoke_grant) }
    return Result(done = Done())
}

internal fun claudeDesignSlice(view: ClaudeDesignView): ClaudeDesignSlice {
    val presented = ClaudeDesignPresentation.of(view)
    return ClaudeDesignSlice(
        daemon_id = view.daemonId.orEmpty(),
        status = view.status,
        loading = view.loading,
        error = view.error.orEmpty(),
        sign_in =
            view.signIn?.let { signIn ->
                ClaudeDesignSignIn(
                    phase =
                        when (signIn.phase) {
                            ClaudeDesignSignInPhase.STARTING ->
                                ClaudeDesignSignIn.Phase.PHASE_STARTING
                            ClaudeDesignSignInPhase.PREPARING ->
                                ClaudeDesignSignIn.Phase.PHASE_PREPARING
                            ClaudeDesignSignInPhase.WAITING ->
                                ClaudeDesignSignIn.Phase.PHASE_WAITING
                            ClaudeDesignSignInPhase.CHECKING_CODE ->
                                ClaudeDesignSignIn.Phase.PHASE_CHECKING_CODE
                            ClaudeDesignSignInPhase.SUCCEEDED ->
                                ClaudeDesignSignIn.Phase.PHASE_SUCCEEDED
                            ClaudeDesignSignInPhase.FAILED -> ClaudeDesignSignIn.Phase.PHASE_FAILED
                        },
                    open_url = presented.openUrl,
                    code_required = presented.codeRequired,
                    message = signIn.message,
                    active = signIn.active,
                )
            },
        access_pending = view.accessPending,
        headline = presented.headline,
        detail = presented.detail,
        access_detail = presented.accessDetail,
        can_sign_in = presented.canSignIn,
        can_change_access = presented.canChangeAccess,
    )
}
