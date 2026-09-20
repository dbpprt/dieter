package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Checkout
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.ValidationCommand
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedDirectoryTest {
    @Test fun replicasKeepBothCheckoutOwnersAndLocalValidation() {
        val a = Checkout.newBuilder().setId("a").setDaemonId("owner-a").setPath("/a/repo")
            .addValidationCommands(ValidationCommand.newBuilder().setName("Test").setExecutable("just").addArguments("test")).build()
        val b = Checkout.newBuilder().setId("b").setDaemonId("owner-b").setPath("/b/repo").build()
        val first = Project.newBuilder().setId("project").setName("Repo").addCheckouts(a).build()
        val second = first.toBuilder().setUpdatedAt("later").clearCheckouts()
            .addCheckouts(a.toBuilder().clearPath().clearValidationCommands()).addCheckouts(b).build()
        val merged = sharedProjects(listOf(first, second)).single()
        assertEquals(listOf("a", "b"), merged.checkoutsList.map { it.id })
        assertEquals("/a/repo", merged.checkoutsList[0].path)
        assertEquals(a.validationCommandsList, merged.checkoutsList[0].validationCommandsList)
    }

    @Test fun detachCannotBeUndoneByStaleReplica() {
        val checkout = Checkout.newBuilder().setId("a").setDaemonId("owner").build()
        val stale = Project.newBuilder().setId("project").addCheckouts(checkout).build()
        val detached = stale.toBuilder().clearCheckouts().addCheckouts(checkout.toBuilder().setDetached(true)).build()
        assertTrue(sharedProjects(listOf(detached, stale)).single().checkoutsList.single().detached)
    }

    @Test fun acceptedIdentityReplacesOptimisticRowAndUnionsOtherOwner() {
        val optimistic = Card.newBuilder().setId("a").setUpdatedAt("2099").build()
        val accepted = optimistic.toBuilder().setOwnerDaemonId("machine-a").setUpdatedAt("2026").build()
        val other = accepted.toBuilder().setId("b").setOwnerDaemonId("machine-b").build()
        assertEquals(listOf(accepted, other), sharedItems(listOf(optimistic, other, accepted)))
    }
}
