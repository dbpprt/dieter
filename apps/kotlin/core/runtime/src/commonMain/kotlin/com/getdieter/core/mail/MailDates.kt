package com.getdieter.core.mail

import kotlin.time.Instant

/** A calendar day in the device's time zone. */
internal data class LocalDay(val epochDay: Long, val year: Int, val month: Int, val day: Int) {
    /** 1 for Monday through 7 for Sunday; 1970-01-01 was a Thursday. */
    val weekday: Int
        get() = ((epochDay + 3).mod(7L) + 1).toInt()

    /** The Monday that starts this day's week. */
    val weekStart: Long
        get() = epochDay - (weekday - 1)

    companion object {
        /** [at]'s day where the zone is [offsetSeconds] ahead of UTC. */
        fun of(at: Instant, offsetSeconds: Int): LocalDay =
            of((at.epochSeconds + offsetSeconds).floorDiv(SECONDS_PER_DAY))

        /** The proleptic Gregorian date of [epochDay] (days since 1970-01-01). */
        fun of(epochDay: Long): LocalDay {
            val shifted = epochDay + 719_468
            val era = shifted.floorDiv(146_097L)
            val dayOfEra = shifted - era * 146_097
            val yearOfEra =
                (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            val monthIndex = (5 * dayOfYear + 2) / 153
            val day = (dayOfYear - (153 * monthIndex + 2) / 5 + 1).toInt()
            val month = (if (monthIndex < 10) monthIndex + 3 else monthIndex - 9).toInt()
            val year = (yearOfEra + era * 400 + if (month <= 2) 1 else 0).toInt()
            return LocalDay(epochDay, year, month, day)
        }

        const val SECONDS_PER_DAY = 86_400L
    }
}

/** Day and time words of the mailbox, in English, in the device's time zone. */
internal object MailDates {
    private val WEEKDAYS = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    private val MONTHS =
        listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    private val MONTH_NAMES =
        listOf(
            "January",
            "February",
            "March",
            "April",
            "May",
            "June",
            "July",
            "August",
            "September",
            "October",
            "November",
            "December",
        )

    fun weekday(day: LocalDay): String = WEEKDAYS[day.weekday - 1]

    /** "12 Oct". */
    fun dayMonth(day: LocalDay): String = "${day.day} ${MONTHS[day.month - 1]}"

    /** "September 2026". */
    fun monthTitle(day: LocalDay): String = "${MONTH_NAMES[day.month - 1]} ${day.year}"

    /** "2026-09". */
    fun monthId(day: LocalDay): String =
        "${day.year.toString().padStart(4, '0')}-${day.month.toString().padStart(2, '0')}"

    /** "09:14", 24-hour. */
    fun clock(at: Instant, offsetSeconds: Int): String {
        val minutes = (at.epochSeconds + offsetSeconds).mod(LocalDay.SECONDS_PER_DAY) / 60
        return "${(minutes / 60).toString().padStart(2, '0')}:${(minutes % 60).toString().padStart(2, '0')}"
    }
}
