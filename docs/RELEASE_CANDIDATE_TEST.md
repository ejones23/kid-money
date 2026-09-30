# Release-candidate physical smoke check

Run after updating both existing installations to the release-candidate
TestFlight build. Update in place; do not uninstall or create a new family
share. Keep real child names, balances, and screenshots out of public issues.

1. On the owner phone, confirm the pre-update children, balances, and history
   are unchanged. The home screen should have Give/Take, individual child
   cards, and All Children last, but no **Undo Last** button.
2. Open **Sharing**. It should still say **Sharing enabled**, but there should
   be no **Connection Test** section. Do not send another invitation.
3. Make one small quick adjustment to a child. Confirm the signed transaction
   appears once in history and the balance changes by exactly that amount.
4. Without using **Sync Now**, let the participant app receive that change.
   Background and foreground it if needed. Confirm one matching transaction
   and balance, then terminate and relaunch both apps to check persistence.
5. Check the home screen and child history in light and dark appearance and
   at a larger text setting. Report clipped amounts, unreadable text, or tap
   targets that overlap. No Siri test is required for this UI-only change.

If sync fails, note each phone's build, Sharing status, and pending-change
count before using **Sync Now**. Do not sign out of iCloud, revoke the share,
or delete either app as a troubleshooting step.
