// Experimental observation only. This mechanism never authorizes an unlock.
#include <Security/AuthorizationPlugin.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <uuid/uuid.h>
#include "ProbeIdentity.h"

static atomic_uint_fast64_t next_mechanism = 1;

static void log_event(os_log_t log, const char *event, const char *instance, uint64_t mechanism) {
#ifdef PROBE_LOG_TEST
    (void)log;
    extern void probe_record_event(const char *, const char *, const char *, uint64_t);
    probe_record_event(event, probe_build_id(), instance, mechanism);
#else
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT,
                    "event=%{public}s build_id=%{public}s instance=%{public}s mechanism=%{public}llu",
                    event, probe_build_id(), instance, (unsigned long long)mechanism);
#endif
}

typedef struct {
    OSStatus (*set_result)(AuthorizationEngineRef, AuthorizationResult);
    OSStatus (*did_deactivate)(AuthorizationEngineRef);
    os_log_t log;
    char instance[37];
} ProbePlugin;

typedef struct {
    ProbePlugin *plugin;
    AuthorizationEngineRef engine;
    uint64_t identifier;
} ProbeMechanism;

static OSStatus plugin_destroy(AuthorizationPluginRef reference) {
    ProbePlugin *plugin = reference;
    // The public ABI guarantees all mechanisms are destroyed before this call.
    os_release(plugin->log);
    free(plugin);
    return errAuthorizationSuccess;
}

static OSStatus mechanism_create(AuthorizationPluginRef reference,
                                 AuthorizationEngineRef engine,
                                 AuthorizationMechanismId identifier,
                                 AuthorizationMechanismRef *output) {
    *output = NULL;
    if (strcmp(identifier, "observe-screensaver") != 0) {
        return errAuthorizationInternal;
    }
    ProbeMechanism *mechanism = calloc(1, sizeof(*mechanism));
    if (mechanism == NULL) {
        return errAuthorizationInternal;
    }
    mechanism->plugin = reference;
    mechanism->engine = engine;
    mechanism->identifier = atomic_fetch_add(&next_mechanism, 1);
    *output = mechanism;
    log_event(mechanism->plugin->log, "mechanism_created", mechanism->plugin->instance, mechanism->identifier);
    return errAuthorizationSuccess;
}

static OSStatus mechanism_invoke(AuthorizationMechanismRef reference) {
    ProbeMechanism *mechanism = reference;
    // Copy these before calling the engine. There is no asynchronous work or wait.
    AuthorizationEngineRef engine = mechanism->engine;
    OSStatus (*set_result)(AuthorizationEngineRef, AuthorizationResult) =
        mechanism->plugin->set_result;
    os_log_t log = mechanism->plugin->log;
    uint64_t identifier = mechanism->identifier;
    char instance[37];
    memcpy(instance, mechanism->plugin->instance, sizeof(instance));
    os_retain(log);
    log_event(log, "mechanism_invoked", instance, identifier);
    OSStatus status = set_result(engine, kAuthorizationResultDeny);
    if (status == errAuthorizationSuccess) {
        log_event(log, "denial_returned", instance, identifier);
    } else {
        log_event(log, "decision_delivery_failed", instance, identifier);
    }
    os_release(log);
    return status;
}

static OSStatus mechanism_deactivate(AuthorizationMechanismRef reference) {
    ProbeMechanism *mechanism = reference;
    log_event(mechanism->plugin->log, "deactivated", mechanism->plugin->instance, mechanism->identifier);
    return mechanism->plugin->did_deactivate(mechanism->engine);
}

static OSStatus mechanism_destroy(AuthorizationMechanismRef reference) {
    ProbeMechanism *mechanism = reference;
    log_event(mechanism->plugin->log, "destroyed", mechanism->plugin->instance, mechanism->identifier);
    free(mechanism);
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
    *output = NULL;
    *output_interface = NULL;
    if (callbacks->SetResult == NULL || callbacks->DidDeactivate == NULL) {
        return errAuthorizationInternal;
    }
    ProbePlugin *plugin = calloc(1, sizeof(*plugin));
    if (plugin == NULL) {
        return errAuthorizationInternal;
    }
    // These callbacks exist in the original ABI. Do not copy the whole table:
    // older hosts need not provide the later callback fields in this SDK.
    plugin->set_result = callbacks->SetResult;
    plugin->did_deactivate = callbacks->DidDeactivate;
    plugin->log = os_log_create("ai.personastack.locked-session-probe", "authorization");
    uuid_t instance;
    uuid_generate_random(instance);
    uuid_unparse_lower(instance, plugin->instance);
    *output = plugin;
    *output_interface = &interface;
    log_event(plugin->log, "plugin_loaded", plugin->instance, 0);
    return errAuthorizationSuccess;
}
