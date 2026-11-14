---
title: Notifications
description: "Task attention alerts, encrypted background push and notification settings on Android and iOS."
group: "Workflows"
slug: "notifications"
weight: 45
---

Android and iOS notify for the Inbox's **Needs you** tasks: unseen model replies
and questions waiting for your answer. Reading a reply on any device marks it
seen. Running turns and archived tasks do not notify, and moving an already-read
task to Review does not create an alert.

Allow notifications when asked after sign-in. Check **Settings → Notifications
→ Dieter** on iOS, or **Settings → Apps → Dieter → Notifications → Tasks needing
you** on Android. Tapping an alert opens its task in Inbox, including after a
cold launch and sign-in. An unavailable task returns you to Inbox.

Local notifications work while Dieter receives updates. Background delivery
requires a gateway configured for **Apple Push Notification service (APNs)** on
iOS or **Firebase Cloud Messaging (FCM)** on Android, plus a correctly configured
app build. A new release alone does not supply that setup. iOS push also requires
a Push Notifications signing profile; it is disabled in the default signing
configuration until that profile is available. Ask your gateway operator to
follow the [mobile notification setup](https://github.com/dbpprt/dieter/blob/main/docs/ios-notifications.md).

Push alerts contain generic text and an encrypted task link. Your task's title
and conversation are not sent to Apple or Google. A task link for another
account cannot open a conversation in your current account.

iOS badges count the tasks needing you. Android launcher dots and numeric badges
depend on the launcher and notification settings. Notifications can be delayed
or dropped by OS and network policies; reopening Dieter reconciles them with the
Inbox. Android requires Google Play services for FCM, and force-stop blocks push
until you launch the app again.
