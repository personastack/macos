## Upgrade notes

- Update PersonaStack for macOS before setting up or managing HermesAgent and OpenClaw connections with the updated web app. Keep existing personas and finish setup on the same profile.

## Changed

- Preserve a persona’s pause setting when moving a previous connection into Background Agents. Send test wake is now a separate action after setup.

## Fixed

- Keep local-agent setup and connection checks tied to the current account and page. Signing out or switching pages cancels stale setup responses.
- Recover from locked or denied Keychain access by allowing access and checking the same connection again.
- Use Review profile to finish cleanup of a revoked local-agent connection before reconnecting the same persona.
- Check the current pause setting when retrying an interrupted migration. An already applied Resume stays in place without another change.
