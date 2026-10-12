## Fixed

- Fixed Desktop Control observation failures after reconnecting, restarting, or updating the app.
- Show recovery steps when a Desktop Control session is unavailable.
- Keep local-agent setup and connection checks tied to the current account and page. Signing out or switching pages cancels stale setup responses.
- Recover from locked or denied Keychain access by allowing access and checking the same connection again.
- Preserve a persona’s pause setting when moving a previous connection into Background Agents. Send test wake is now a separate action after setup.
- Use Review profile to finish cleanup of a revoked local-agent connection before reconnecting the same persona.
- Check the current pause setting when retrying an interrupted migration. An already applied Resume stays in place without another change.
