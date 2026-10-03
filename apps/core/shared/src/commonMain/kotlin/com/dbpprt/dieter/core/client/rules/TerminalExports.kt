package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.TerminalKey
import com.dbpprt.dieter.core.terminals.TerminalKeys
import com.dbpprt.dieter.core.terminals.TerminalsView

/** The bytes a terminal's accessory keys send, as a native terminal view writes them to the terminal's input, and its status line. */
object TerminalExports {
    /**
     * The bytes [key] (a `TerminalKey` value) sends with the held modifiers;
     * empty for an unknown key. [applicationCursor] is the terminal's DECCKM
     * mode, which the renderer tracks.
     */
    fun key(key: Int, shift: Boolean, alt: Boolean, control: Boolean, applicationCursor: Boolean): ByteArray =
        TerminalKeys.sequence(TerminalKey.fromValue(key) ?: TerminalKey.TERMINAL_KEY_UNSPECIFIED, shift, alt, control, applicationCursor)

    /** A `TerminalKey` value for F[number], 0 outside F1 to F12. */
    fun functionKey(number: Int): Int = TerminalKeys.function(number)?.value ?: 0

    /** What an armed Control turns one typed key into; null when Control does not apply. */
    fun control(bytes: ByteArray): ByteArray? = TerminalKeys.control(bytes)

    /** A terminal's status line, as [TerminalsView.terminalStatus] words it; [exitCode] counts only with [hasExitCode]. */
    fun status(status: String, exitCode: Int, hasExitCode: Boolean, streamConnected: Boolean): String =
        TerminalsView.terminalStatus(status, exitCode.takeIf { hasExitCode }, streamConnected)
}
