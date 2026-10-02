#include "LockedControlAudit.h"

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecCode.h>
#include <Security/SecRequirement.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <bsm/libbsm.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int code_for_audit_token(const audit_token_t *token, SecCodeRef *code) {
    *code = NULL;
    CFDataRef token_data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)token, sizeof(*token));
    if (token_data == NULL) return 0;
    const void *keys[] = {kSecGuestAttributeAudit};
    const void *values[] = {token_data};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
    CFRelease(token_data);
    if (attributes == NULL) return 0;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, code);
    CFRelease(attributes);
    return status == errSecSuccess && *code != NULL;
}

static int check_requirement(SecCodeRef code, const char *requirement_text) {
    CFStringRef requirement_string = CFStringCreateWithCString(kCFAllocatorDefault, requirement_text,
                                                               kCFStringEncodingUTF8);
    if (requirement_string == NULL) return 0;
    SecRequirementRef requirement = NULL;
    OSStatus status = SecRequirementCreateWithString(requirement_string, kSecCSDefaultFlags, &requirement);
    CFRelease(requirement_string);
    if (status != errSecSuccess || requirement == NULL) return 0;
    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    CFRelease(requirement);
    return status == errSecSuccess;
}

static int requirement_for_pinned_certificate(const uint8_t *certificate, size_t length,
                                              char *output, size_t capacity) {
    if (certificate == NULL || length == 0 || length > 16384) return 0;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    if (CC_SHA1(certificate, (CC_LONG)length, digest) == NULL) return 0;
    int prefix = snprintf(output, capacity,
                          "identifier \"ai.personastack.desktop\" and certificate leaf = H\"");
    if (prefix < 0 || (size_t)prefix + sizeof(digest) * 2 + 2 > capacity) return 0;
    size_t offset = (size_t)prefix;
    for (size_t index = 0; index < sizeof(digest); index++) {
        int part = snprintf(output + offset, capacity - offset, "%02x", digest[index]);
        if (part != 2) return 0;
        offset += 2;
    }
    return strlcat(output, "\"", capacity) < capacity;
}

static int peer_token(int socket_fd, audit_token_t *token) {
    memset(token, 0, sizeof(*token));
    socklen_t length = sizeof(*token);
    return getsockopt(socket_fd, SOL_LOCAL, LOCAL_PEERTOKEN, token, &length) == 0 && length == sizeof(*token);
}

static int verify_socket_peer(int socket_fd, const char *requirement_text,
                              int32_t *process_id, uint32_t *effective_user_id,
                              uint32_t *audit_session_id) {
    audit_token_t token;
    if (!peer_token(socket_fd, &token)) return 0;
    SecCodeRef code = NULL;
    if (!code_for_audit_token(&token, &code)) return 0;
    int valid = check_requirement(code, requirement_text);
    CFRelease(code);
    if (!valid) return 0;
    if (process_id != NULL) *process_id = (int32_t)audit_token_to_pid(token);
    if (effective_user_id != NULL) *effective_user_id = (uint32_t)audit_token_to_euid(token);
    if (audit_session_id != NULL) *audit_session_id = (uint32_t)audit_token_to_asid(token);
    return 1;
}

int PSCurrentAuditSessionID(uint32_t *session_id) {
    if (session_id == NULL) return 0;
    auditinfo_addr_t information;
    memset(&information, 0, sizeof(information));
    if (getaudit_addr(&information, sizeof(information)) != 0 || information.ai_asid == AU_DEFAUDITSID) return 0;
    *session_id = (uint32_t)information.ai_asid;
    return 1;
}

int PSCurrentConsoleUserID(uint32_t *user_id) {
    if (user_id == NULL) return 0;
    SCDynamicStoreRef store = SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("PersonaStackLockedGrant"), NULL, NULL);
    if (store == NULL) return 0;
    uid_t uid = 0;
    gid_t gid = 0;
    CFStringRef username = SCDynamicStoreCopyConsoleUser(store, &uid, &gid);
    CFRelease(store);
    if (username == NULL) return 0;
    CFRelease(username);
    if (uid == 0) return 0;
    *user_id = (uint32_t)uid;
    return 1;
}

int PSVerifyAuthorizationHostPeer(int socket_fd, int32_t *process_id,
                                  uint32_t *effective_user_id, uint32_t *audit_session_id) {
    uint32_t peer_uid = 0;
    if (!verify_socket_peer(socket_fd,
                            "anchor apple and identifier \"com.apple.authorizationhost\"",
                            process_id, &peer_uid, audit_session_id) || peer_uid != 0) return 0;
    if (effective_user_id != NULL) *effective_user_id = peer_uid;
    return 1;
}

int PSVerifyPersonaStackPeer(int socket_fd, const uint8_t *leaf_certificate,
                             size_t certificate_length, int32_t *process_id,
                             uint32_t *effective_user_id, uint32_t *audit_session_id) {
    char requirement[160] = {0};
    if (!requirement_for_pinned_certificate(leaf_certificate, certificate_length,
                                            requirement, sizeof(requirement))) return 0;
    return verify_socket_peer(socket_fd, requirement, process_id, effective_user_id, audit_session_id);
}

int PSVerifyPersonaStackSelf(const uint8_t *leaf_certificate, size_t certificate_length) {
    char requirement[160] = {0};
    if (!requirement_for_pinned_certificate(leaf_certificate, certificate_length,
                                            requirement, sizeof(requirement))) return 0;
    SecCodeRef self = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess || self == NULL) return 0;
    int valid = check_requirement(self, requirement);
    CFRelease(self);
    return valid;
}
