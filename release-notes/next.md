## Upgrade notes

- Update PersonaStack for macOS before setting up or managing HermesAgent and OpenClaw connections with the updated web app. Keep existing personas and finish setup on the same profile.

## Changed

- Set up HermesAgent and OpenClaw through Background Agents in the macOS app. Setup preserves the persona’s pause setting. Send test wake is a separate action.

## Fixed

- Keep Refresh, Back, and Forward visible when opening desktop menu flows or reopening the main window.
- Return to the persona list after closing and reopening the main window. Menu actions and notification links still open their selected destination.
- Release Google sign-in windows when they close.
- Keep pop-outs open when navigation is canceled. Clean up closed chats and retain keyboard focus and Close in collapsed chats.

- Keep local-agent setup and connection checks tied to the current account and page. Signing out or switching pages cancels stale setup responses.
- Recover from locked or denied Keychain access by allowing access and checking the same connection again.
- Use Review profile to finish cleanup of a revoked local-agent connection before reconnecting the same persona.
