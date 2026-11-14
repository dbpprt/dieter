package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopICECandidate
import com.getdieter.api.v1.RemoteDesktopSessionBinding
import com.getdieter.api.v1.RemoteDesktopSignal
import com.getdieter.api.v1.StartRemoteDesktopRequest
import com.getdieter.core.platform.SignatureVerifier
import kotlin.time.Clock

/**
 * The answering half of one attempt's offer/answer exchange: the daemon's signed binding, the
 * host's answer, and its network candidates. Neither may change once received, and the answer
 * applies only after both were verified against the request and the machine's enrolled identity
 * ([ScreenTrust]); candidates wait for it. [ScreenSession] owns it and resets it with each attempt;
 * confined to the core dispatcher.
 */
internal class ScreenNegotiation(
    private val verifier: SignatureVerifier,
    private val clock: Clock,
) {
    /** The daemon's binding of this session, once received. */
    var binding: RemoteDesktopSessionBinding? = null
        private set

    /** The binding and answer were verified. */
    var authorized = false
        private set

    private var answer: String? = null
    private var remoteApplied = false
    private val remoteCandidates = ArrayDeque<RemoteDesktopICECandidate>()

    /**
     * Takes [received]'s binding, answer, and candidate; returns why the session must fail, or
     * null. A candidate goes to [engine] once the answer applied and waits until then.
     */
    suspend fun receive(received: RemoteDesktopSignal, engine: ScreenMediaEngine?): String? {
        received.binding?.let { incoming ->
            val stored = binding
            if (stored != null && stored != incoming) return "The screen session binding changed."
            binding = incoming
        }
        received.description?.let { description ->
            if (description.type != "answer") return "The screen host sent an invalid answer."
            val stored = answer
            if (stored != null && stored != description.sdp)
                return "The screen host changed its answer."
            answer = description.sdp
        }
        received.candidate?.let { candidate ->
            if (remoteApplied) {
                engine?.addRemoteCandidate(candidate)
            } else {
                if (remoteCandidates.size >= ScreenSessionPolicy.MAX_CANDIDATES)
                    return "The screen host sent too many network candidates."
                remoteCandidates.addLast(candidate)
            }
        }
        return null
    }

    /**
     * Verifies the binding and answer of [sessionId] once both arrived, throwing
     * [ScreenTrustException] when they do not match [request] or [route]'s identity. Returns the
     * newly authorized binding, or null while something is missing or after the first time.
     */
    fun verify(
        sessionId: String,
        request: StartRemoteDesktopRequest?,
        route: ScreenRoute?,
    ): RemoteDesktopSessionBinding? {
        if (authorized) return null
        val boundSession = binding ?: return null
        val sdp = answer ?: return null
        val start = request ?: return null
        val current = route ?: return null
        ScreenTrust.verify(
            boundSession,
            sessionId,
            start,
            sdp,
            current.daemonPublicKey,
            clock.now(),
            verifier,
        )
        authorized = true
        return boundSession
    }

    /** Applies the verified answer to [engine], then the candidates that waited for it. */
    suspend fun applyAnswer(engine: ScreenMediaEngine?) {
        engine?.applyAnswer(checkNotNull(answer))
        remoteApplied = true
        while (remoteCandidates.isNotEmpty()) engine?.addRemoteCandidate(
            remoteCandidates.removeFirst()
        )
    }

    /** Forgets the stopped attempt's exchange. */
    fun reset() {
        authorized = false
        binding = null
        answer = null
        remoteApplied = false
        remoteCandidates.clear()
    }
}
