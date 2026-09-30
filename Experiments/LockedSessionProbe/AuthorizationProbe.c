// Experimental observation only. This mechanism never authorizes an unlock.
#include <Security/AuthorizationPlugin.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    OSStatus (*set_result)(AuthorizationEngineRef, AuthorizationResult);
    OSStatus (*did_deactivate)(AuthorizationEngineRef);
    os_log_t log;
} ProbePlugin;

typedef struct {
    ProbePlugin *plugin;
    AuthorizationEngineRef engine;
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
    *output = mechanism;
    os_log_with_type(mechanism->plugin->log, OS_LOG_TYPE_DEFAULT, "mechanism_created");
    return errAuthorizationSuccess;
}

static OSStatus mechanism_invoke(AuthorizationMechanismRef reference) {
    ProbeMechanism *mechanism = reference;
    // Copy these before calling the engine. There is no asynchronous work or wait.
    AuthorizationEngineRef engine = mechanism->engine;
    OSStatus (*set_result)(AuthorizationEngineRef, AuthorizationResult) =
        mechanism->plugin->set_result;
    os_log_t log = mechanism->plugin->log;
    os_retain(log);
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "mechanism_invoked");
    OSStatus status = set_result(engine, kAuthorizationResultDeny);
    if (status == errAuthorizationSuccess) {
        os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "denial_returned");
    } else {
        os_log_with_type(log, OS_LOG_TYPE_ERROR, "decision_delivery_failed");
    }
    os_release(log);
    return status;
}

static OSStatus mechanism_deactivate(AuthorizationMechanismRef reference) {
    ProbeMechanism *mechanism = reference;
    os_log_with_type(mechanism->plugin->log, OS_LOG_TYPE_DEFAULT, "deactivated");
    return mechanism->plugin->did_deactivate(mechanism->engine);
}

static OSStatus mechanism_destroy(AuthorizationMechanismRef reference) {
    ProbeMechanism *mechanism = reference;
    os_log_with_type(mechanism->plugin->log, OS_LOG_TYPE_DEFAULT, "destroyed");
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
    *output = plugin;
    *output_interface = &interface;
    os_log_with_type(plugin->log, OS_LOG_TYPE_DEFAULT, "plugin_loaded");
    return errAuthorizationSuccess;
}
