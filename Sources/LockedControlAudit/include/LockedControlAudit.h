#ifndef PERSONASTACK_LOCKED_CONTROL_AUDIT_H
#define PERSONASTACK_LOCKED_CONTROL_AUDIT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

int PSCurrentAuditSessionID(uint32_t *session_id);
int PSCurrentConsoleUserID(uint32_t *user_id);
int PSVerifyAuthorizationHostPeer(int socket_fd, int32_t *process_id,
                                  uint32_t *effective_user_id, uint32_t *audit_session_id);
int PSVerifyPersonaStackPeer(int socket_fd, const uint8_t *leaf_certificate,
                             size_t certificate_length, int32_t *process_id,
                             uint32_t *effective_user_id, uint32_t *audit_session_id);
int PSVerifyPersonaStackSelf(const uint8_t *leaf_certificate, size_t certificate_length);

#endif
