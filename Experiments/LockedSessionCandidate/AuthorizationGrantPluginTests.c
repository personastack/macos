#include <Security/AuthorizationPlugin.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

void PSLockedGrantTestSetGrantResult(int allow);

static AuthorizationResult last_result;
static unsigned int set_result_calls;
static unsigned int deactivate_calls;
static OSStatus set_result_status;
static OSStatus deactivate_status;

static OSStatus test_set_result(AuthorizationEngineRef engine, AuthorizationResult result) {
    (void)engine;
    last_result = result;
    set_result_calls++;
    return set_result_status;
}

static OSStatus test_did_deactivate(AuthorizationEngineRef engine) {
    (void)engine;
    deactivate_calls++;
    return deactivate_status;
}

static AuthorizationCallbacks callbacks(void) {
    AuthorizationCallbacks value;
    memset(&value, 0, sizeof(value));
    value.version = kAuthorizationCallbacksVersion;
    value.SetResult = test_set_result;
    value.DidDeactivate = test_did_deactivate;
    return value;
}

static void reset_callbacks(void) {
    last_result = kAuthorizationResultUndefined;
    set_result_calls = 0;
    deactivate_calls = 0;
    set_result_status = errAuthorizationSuccess;
    deactivate_status = errAuthorizationSuccess;
}

int main(void) {
    AuthorizationCallbacks engine_callbacks = callbacks();
    AuthorizationPluginRef plugin = NULL;
    const AuthorizationPluginInterface *interface = NULL;
    assert(AuthorizationPluginCreate(&engine_callbacks, &plugin, &interface) == errAuthorizationSuccess);
    assert(plugin != NULL && interface != NULL);
    assert(interface->version == kAuthorizationPluginInterfaceVersion);

    AuthorizationMechanismRef mechanism = NULL;
    AuthorizationEngineRef engine = (AuthorizationEngineRef)&engine_callbacks;
    assert(interface->MechanismCreate(plugin, engine,
                                      (AuthorizationMechanismId)"consume-locked-grant",
                                      &mechanism) == errAuthorizationSuccess);
    assert(mechanism != NULL);

    reset_callbacks();
    PSLockedGrantTestSetGrantResult(1);
    assert(interface->MechanismInvoke(mechanism) == errAuthorizationSuccess);
    assert(set_result_calls == 1 && last_result == kAuthorizationResultAllow);

    reset_callbacks();
    PSLockedGrantTestSetGrantResult(0);
    assert(interface->MechanismInvoke(mechanism) == errAuthorizationSuccess);
    assert(set_result_calls == 1 && last_result == kAuthorizationResultDeny);

    reset_callbacks();
    set_result_status = errAuthorizationDenied;
    PSLockedGrantTestSetGrantResult(1);
    assert(interface->MechanismInvoke(mechanism) == errAuthorizationDenied);
    assert(set_result_calls == 1 && last_result == kAuthorizationResultAllow);

    reset_callbacks();
    deactivate_status = errAuthorizationInternal;
    assert(interface->MechanismDeactivate(mechanism) == errAuthorizationInternal);
    assert(deactivate_calls == 1);

    assert(interface->MechanismDestroy(mechanism) == errAuthorizationSuccess);
    mechanism = (AuthorizationMechanismRef)1;
    assert(interface->MechanismCreate(plugin, engine,
                                      (AuthorizationMechanismId)"unknown-mechanism",
                                      &mechanism) == errAuthorizationInternal);
    assert(mechanism == NULL);
    mechanism = (AuthorizationMechanismRef)1;
    AuthorizationCallbacks malformed = engine_callbacks;
    malformed.SetResult = NULL;
    AuthorizationPluginRef rejected_plugin = (AuthorizationPluginRef)1;
    const AuthorizationPluginInterface *rejected_interface = (const AuthorizationPluginInterface *)1;
    assert(AuthorizationPluginCreate(&malformed, &rejected_plugin, &rejected_interface) == errAuthorizationInternal);
    assert(rejected_plugin == NULL && rejected_interface == NULL);
    malformed = engine_callbacks;
    malformed.DidDeactivate = NULL;
    assert(AuthorizationPluginCreate(&malformed, &rejected_plugin, &rejected_interface) == errAuthorizationInternal);
    assert(rejected_plugin == NULL && rejected_interface == NULL);
    const AuthorizationCallbacks *missing_callbacks = NULL;
    assert(AuthorizationPluginCreate(missing_callbacks, &rejected_plugin, &rejected_interface) == errAuthorizationInternal);
    assert(rejected_plugin == NULL && rejected_interface == NULL);
    AuthorizationPluginRef *missing_plugin_output = NULL;
    const AuthorizationPluginInterface **missing_interface_output = NULL;
    assert(AuthorizationPluginCreate(&engine_callbacks, missing_plugin_output, &rejected_interface) == errAuthorizationInternal);
    assert(AuthorizationPluginCreate(&engine_callbacks, &rejected_plugin, missing_interface_output) == errAuthorizationInternal);

    assert(interface->PluginDestroy(plugin) == errAuthorizationSuccess);
    puts("authorization plugin callback tests passed");
    return 0;
}
