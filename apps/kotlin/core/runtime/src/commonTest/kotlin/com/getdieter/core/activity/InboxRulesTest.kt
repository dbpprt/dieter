package com.getdieter.core.activity

import com.getdieter.api.v1.Card
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class InboxRulesTest {
    private val urgentInApp = Card(id = "a", project_id = "app", label_ids = listOf("urgent"))
    private val plainInApp = Card(id = "b", project_id = "app")
    private val urgentInSite = Card(id = "c", project_id = "site", label_ids = listOf("urgent"))
    private val plainInSite = Card(id = "d", project_id = "site", label_ids = listOf("docs"))
    private val all = listOf(urgentInApp, plainInApp, urgentInSite, plainInSite)

    private fun shown(vararg rules: InboxRule) =
        all.filter { InboxFilter(rules.toList()).shows(it) }.map { it.id }

    @Test
    fun noRulesShowEverything() {
        assertEquals(listOf("a", "b", "c", "d"), shown())
        assertTrue(InboxFilter(emptyList()).isEmpty)
    }

    @Test
    fun hidingAProjectDropsItsCards() {
        assertEquals(listOf("c", "d"), shown(InboxRule("r", projects = setOf("app"))))
    }

    @Test
    fun hidingALabelDropsItsCardsInEveryProject() {
        assertEquals(listOf("b", "d"), shown(InboxRule("r", labels = setOf("urgent"))))
    }

    @Test
    fun aRuleMatchesEitherConditionOrBothWhenAllIsRequired() {
        val either = InboxRule("r", projects = setOf("app"), labels = setOf("docs"))
        assertEquals(listOf("c"), shown(either))
        assertEquals(listOf("a", "b", "c", "d"), shown(either.copy(matchAll = true)))
        val both =
            InboxRule("r", projects = setOf("app"), labels = setOf("urgent"), matchAll = true)
        assertEquals(listOf("b", "c", "d"), shown(both))
    }

    @Test
    fun showingRulesKeepOnlyWhatTheyMatchAndHidingRulesStillWin() {
        val onlyUrgent = InboxRule("s", hide = false, labels = setOf("urgent"))
        assertEquals(listOf("a", "c"), shown(onlyUrgent))
        val another = InboxRule("t", hide = false, projects = setOf("site"))
        assertEquals(listOf("a", "c", "d"), shown(onlyUrgent, another))
        val quietSite = InboxRule("h", projects = setOf("site"))
        assertEquals(listOf("a"), shown(onlyUrgent, another, quietSite))
    }

    @Test
    fun disabledAndEmptyRulesHaveNoEffect() {
        assertEquals(
            listOf("a", "b", "c", "d"),
            shown(
                InboxRule("off", projects = setOf("app"), enabled = false),
                InboxRule("none"),
                InboxRule("show-off", hide = false, labels = setOf("urgent"), enabled = false),
            ),
        )
    }

    @Test
    fun rulesRoundTripThroughTheirSharedJsonAndIgnoreGarbage() {
        val rule =
            InboxRule(
                "r1",
                name = "Quiet",
                hide = false,
                matchAll = true,
                projects = setOf("p2", "p1"),
                labels = setOf("l1"),
                enabled = false,
                created = 42,
            )
        assertEquals(rule, InboxRule.parse("r1", rule.toJson().toString()))
        assertEquals(
            """{"name":"Quiet","effect":"show","match":"all","projects":["p1","p2"],"labels":["l1"],"enabled":false,"created":42}""",
            rule.toJson().toString(),
        )
        assertNull(InboxRule.parse("r2", "true"))
        assertNull(InboxRule.parse("r3", "not json"))
        assertFalse(InboxRule.parse("r4", "{}")!!.active)
    }
}

class InboxRuleTextTest {
    @Test
    fun summariesNameTheConditionsAndEndLongListsInACount() {
        assertEquals(
            "Hide project dieter, wallfly or label urgent",
            InboxRuleText.summary(true, false, listOf("dieter", "wallfly"), listOf("urgent")),
        )
        assertEquals(
            "Show only project a, b, c +2 and label x",
            InboxRuleText.summary(false, true, listOf("a", "b", "c", "d", "e"), listOf("x")),
        )
        assertEquals("Hide label x", InboxRuleText.summary(true, true, emptyList(), listOf("x")))
        assertEquals(
            "Hide nothing yet",
            InboxRuleText.summary(true, false, emptyList(), emptyList()),
        )
    }
}
