#include <Security/AuthorizationPlugin.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <LockedControlAudit.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <poll.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <uuid/uuid.h>

#include "GrantIPC.h"

typedef struct {
    OSStatus (*set_result)(AuthorizationEngineRef, AuthorizationResult);
    OSStatus (*did_deactivate)(AuthorizationEngineRef);
} GrantPlugin;

typedef struct {
    GrantPlugin *plugin;
    AuthorizationEngineRef engine;
} GrantMechanism;

static int grant_request_from_broker(void);
static int (*grant_request_callback)(void) = grant_request_from_broker;

static uint64_t monotonic_nanoseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static int wait_for(int fd, short events, uint64_t deadline) {
    for (;;) {
        uint64_t now = monotonic_nanoseconds();
        if (now == 0 || now >= deadline) return 0;
        uint64_t remaining = deadline - now;
        int timeout_ms = (int)((remaining + 999999ULL) / 1000000ULL);
        struct pollfd descriptor = {.fd = fd, .events = events};
        int result = poll(&descriptor, 1, timeout_ms);
        if (result > 0) return (descriptor.revents & (events | POLLERR | POLLHUP | POLLNVAL)) != 0;
        if (result == 0) return 0;
        if (errno != EINTR) return 0;
    }
}

static int connect_until(int fd, const struct sockaddr *address, socklen_t address_length, uint64_t deadline) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return 0;
    if (connect(fd, address, address_length) == 0) return 1;
    if (errno != EINPROGRESS || !wait_for(fd, POLLOUT, deadline)) return 0;
    int error = 0;
    socklen_t error_length = sizeof(error);
    return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_length) == 0 && error == 0;
}

static int read_exact(int fd, uint8_t *buffer, size_t length, uint64_t deadline) {
    size_t offset = 0;
    while (offset < length) {
        if (!wait_for(fd, POLLIN, deadline)) return 0;
        ssize_t amount = recv(fd, buffer + offset, length - offset, 0);
        if (amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        if (amount <= 0) return 0;
        offset += (size_t)amount;
    }
    return 1;
}

static int write_exact(int fd, const uint8_t *buffer, size_t length, uint64_t deadline) {
    size_t offset = 0;
    while (offset < length) {
        if (!wait_for(fd, POLLOUT, deadline)) return 0;
        ssize_t amount = send(fd, buffer + offset, length - offset, 0);
        if (amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        if (amount <= 0) return 0;
        offset += (size_t)amount;
    }
    return 1;
}

static int load_pinned_certificate(uint8_t *certificate, size_t capacity, size_t *length) {
    *length = 0;
    Dl_info image = {0};
    if (dladdr((const void *)&AuthorizationPluginCreate, &image) == 0 || image.dli_fname == NULL) return 0;
    char certificate_path[PATH_MAX];
    const char *marker = strstr(image.dli_fname, "/Contents/MacOS/");
    if (marker == NULL) return 0;
    size_t prefix = (size_t)(marker - image.dli_fname);
    if (prefix + sizeof("/Contents/Resources/ReleaseSigningCertificate.der") > sizeof(certificate_path)) return 0;
    memcpy(certificate_path, image.dli_fname, prefix);
    certificate_path[prefix] = '\0';
    strlcat(certificate_path, "/Contents/Resources/ReleaseSigningCertificate.der", sizeof(certificate_path));

    int fd = open(certificate_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat metadata;
    if (fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != 0 ||
        (metadata.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) != 0 || metadata.st_size <= 0 ||
        (uint64_t)metadata.st_size >= capacity) {
        close(fd);
        return 0;
    }
    size_t offset = 0;
    while (offset < (size_t)metadata.st_size) {
        ssize_t count = read(fd, certificate + offset, (size_t)metadata.st_size - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            close(fd);
            return 0;
        }
        offset += (size_t)count;
    }
    close(fd);
    *length = offset;
    return 1;
}

static int grant_request_from_broker(void) {
    SCDynamicStoreRef store = SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("PersonaStackLockedGrant"), NULL, NULL);
    if (store == NULL) return 0;
    uid_t console_uid = 0;
    gid_t console_gid = 0;
    CFStringRef username = SCDynamicStoreCopyConsoleUser(store, &console_uid, &console_gid);
    CFRelease(store);
    if (username == NULL || console_uid == 0) {
        if (username != NULL) CFRelease(username);
        return 0;
    }
    CFRelease(username);

    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int path_length = snprintf(socket_path, sizeof(socket_path), "/tmp/personastack-locked-grant-%u.sock", console_uid);
    if (path_length <= 0 || (size_t)path_length >= sizeof(socket_path)) return 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    int no_sigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    uint64_t now = monotonic_nanoseconds();
    if (now == 0 || now > UINT64_MAX - 1000000000ULL) { close(fd); return 0; }
    uint64_t deadline = now + 1000000000ULL;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socket_path, sizeof(address.sun_path));
    address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + strlen(address.sun_path) + 1);
    uint8_t certificate[16384];
    size_t certificate_length = 0;
    uint32_t broker_user_id = 0;
    uint32_t broker_session_id = 0;
    uint32_t current_session_id = 0;
    if (!load_pinned_certificate(certificate, sizeof(certificate), &certificate_length) ||
        !connect_until(fd, (struct sockaddr *)&address, address.sun_len, deadline) ||
        !PSVerifyPersonaStackPeer(fd, certificate, certificate_length, NULL,
                                  &broker_user_id, &broker_session_id) ||
        PSCurrentAuditSessionID(&current_session_id) != 1 ||
        broker_user_id != (uint32_t)console_uid || broker_session_id != current_session_id) {
        close(fd);
        return 0;
    }

    uuid_t nonce;
    uuid_generate_random(nonce);
    uint8_t request[PS_LOCKED_GRANT_REQUEST_SIZE] = {0};
    memcpy(request, PS_LOCKED_GRANT_REQUEST_MAGIC, PS_LOCKED_GRANT_MAGIC_SIZE);
    request[4] = PS_LOCKED_GRANT_VERSION;
    request[5] = PS_LOCKED_GRANT_OPERATION_CONSUME;
    memcpy(request + PS_LOCKED_GRANT_HEADER_SIZE, nonce, sizeof(nonce));
    uint8_t response[PS_LOCKED_GRANT_RESPONSE_SIZE] = {0};
    int completed = write_exact(fd, request, sizeof(request), deadline) &&
        read_exact(fd, response, sizeof(response), deadline);
    close(fd);
    return completed && memcmp(response, PS_LOCKED_GRANT_RESPONSE_MAGIC, PS_LOCKED_GRANT_MAGIC_SIZE) == 0 &&
        response[4] == PS_LOCKED_GRANT_VERSION && response[5] == 1 &&
        response[6] == 0 && response[7] == 0 &&
        memcmp(response + PS_LOCKED_GRANT_HEADER_SIZE, nonce, sizeof(nonce)) == 0;
}

#if defined(PERSONASTACK_LOCKED_GRANT_TESTING)
static int test_grant_result;

static int test_grant_request(void) {
    return test_grant_result;
}

void PSLockedGrantTestSetGrantResult(int allow) {
    test_grant_result = allow != 0;
    grant_request_callback = test_grant_request;
}
#endif

static OSStatus plugin_destroy(AuthorizationPluginRef reference) {
    free(reference);
    return errAuthorizationSuccess;
}

static OSStatus mechanism_create(AuthorizationPluginRef reference,
                                 AuthorizationEngineRef engine,
                                 AuthorizationMechanismId identifier,
                                 AuthorizationMechanismRef *output) {
    *output = NULL;
    if (identifier == NULL || strcmp(identifier, "consume-locked-grant") != 0) return errAuthorizationInternal;
    GrantMechanism *mechanism = calloc(1, sizeof(*mechanism));
    if (mechanism == NULL) return errAuthorizationInternal;
    mechanism->plugin = reference;
    mechanism->engine = engine;
    *output = mechanism;
    return errAuthorizationSuccess;
}

static OSStatus mechanism_invoke(AuthorizationMechanismRef reference) {
    GrantMechanism *mechanism = reference;
    AuthorizationResult result = grant_request_callback() ? kAuthorizationResultAllow : kAuthorizationResultDeny;
    return mechanism->plugin->set_result(mechanism->engine, result);
}

static OSStatus mechanism_deactivate(AuthorizationMechanismRef reference) {
    GrantMechanism *mechanism = reference;
    return mechanism->plugin->did_deactivate(mechanism->engine);
}

static OSStatus mechanism_destroy(AuthorizationMechanismRef reference) {
    free(reference);
    return errAuthorizationSuccess;
}

static const AuthorizationPluginInterface interface = {
    .version = kAuthorizationPluginInterfaceVersion,
    .PluginDestroy = plugin_destroy,
    .MechanismCreate = mechanism_create,
    .MechanismInvoke = mechanism_invoke,
    .MechanismDeactivate = mechanism_deactivate,
    .MechanismDestroy = mechanism_destroy,
};

__attribute__((visibility("default")))
OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks,
                                   AuthorizationPluginRef *output,
                                   const AuthorizationPluginInterface **output_interface) {
    if (output == NULL || output_interface == NULL) return errAuthorizationInternal;
    *output = NULL;
    *output_interface = NULL;
    if (callbacks == NULL || callbacks->SetResult == NULL || callbacks->DidDeactivate == NULL) {
        return errAuthorizationInternal;
    }
    GrantPlugin *plugin = calloc(1, sizeof(*plugin));
    if (plugin == NULL) return errAuthorizationInternal;
    plugin->set_result = callbacks->SetResult;
    plugin->did_deactivate = callbacks->DidDeactivate;
    *output = plugin;
    *output_interface = &interface;
    return errAuthorizationSuccess;
}
