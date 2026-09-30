// In-process ABI tests only. Never requests an OS right or loads an authhost.
#include <Security/AuthorizationPlugin.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "check failed at line %d: %s\n", __LINE__, #condition); \
        abort(); \
    } \
} while (0)

typedef struct {
    unsigned int decisions;
    unsigned int deactivations;
    unsigned int expected_decisions;
    unsigned int expected_deactivations;
    OSStatus decision_status;
    OSStatus deactivation_status;
} FakeEngine;

typedef struct {
    AuthorizationPluginRef plugin;
    const AuthorizationPluginInterface *interface;
} Fixture;

static OSStatus set_result(AuthorizationEngineRef reference, AuthorizationResult result) {
    FakeEngine *engine = (FakeEngine *)reference;
    CHECK(result == kAuthorizationResultDeny);
    CHECK(engine->decisions < engine->expected_decisions);
    engine->decisions++;
    return engine->decision_status;
}

static OSStatus did_deactivate(AuthorizationEngineRef reference) {
    FakeEngine *engine = (FakeEngine *)reference;
    CHECK(engine->deactivations < engine->expected_deactivations);
    engine->deactivations++;
    return engine->deactivation_status;
}

static OSStatus unexpected_interrupt(AuthorizationEngineRef reference) {
    (void)reference;
    CHECK(0 && "RequestInterrupt must never be called");
    return errAuthorizationInternal;
}

static AuthorizationCallbacks callbacks(void) {
    return (AuthorizationCallbacks){
        .version = kAuthorizationCallbacksVersion,
        .SetResult = set_result,
        .RequestInterrupt = unexpected_interrupt,
        .DidDeactivate = did_deactivate,
    };
}

static Fixture create_fixture(const AuthorizationCallbacks *table) {
    Fixture fixture = {0};
    CHECK(AuthorizationPluginCreate(table, &fixture.plugin, &fixture.interface) ==
          errAuthorizationSuccess);
    CHECK(fixture.plugin != NULL && fixture.interface != NULL);
    CHECK(fixture.interface->version == kAuthorizationPluginInterfaceVersion);
    CHECK(fixture.interface->PluginDestroy != NULL);
    CHECK(fixture.interface->MechanismCreate != NULL);
    CHECK(fixture.interface->MechanismInvoke != NULL);
    CHECK(fixture.interface->MechanismDeactivate != NULL);
    CHECK(fixture.interface->MechanismDestroy != NULL);
    return fixture;
}

static AuthorizationMechanismRef create_mechanism(Fixture fixture, FakeEngine *engine) {
    AuthorizationMechanismRef mechanism = NULL;
    CHECK(fixture.interface->MechanismCreate(fixture.plugin,
          (AuthorizationEngineRef)engine, "observe-screensaver", &mechanism) ==
          errAuthorizationSuccess);
    CHECK(mechanism != NULL);
    CHECK(engine->decisions == 0 && engine->deactivations == 0);
    return mechanism;
}

static void verify_engine(FakeEngine engine) {
    CHECK(engine.decisions == engine.expected_decisions);
    CHECK(engine.deactivations == engine.expected_deactivations);
}

static void test_required_callbacks(void) {
    for (unsigned int missing = 0; missing < 3; missing++) {
        AuthorizationCallbacks table = callbacks();
        if (missing != 1) table.SetResult = NULL;
        if (missing != 0) table.DidDeactivate = NULL;
        AuthorizationPluginRef plugin = &table;
        AuthorizationPluginInterface sentinel = {0};
        const AuthorizationPluginInterface *interface = &sentinel;
        CHECK(AuthorizationPluginCreate(&table, &plugin, &interface) == errAuthorizationInternal);
        CHECK(plugin == NULL && interface == NULL);
    }
}

static void test_unknown_mechanism(void) {
    AuthorizationCallbacks table = callbacks();
    Fixture fixture = create_fixture(&table);
    FakeEngine engine = {0};
    const char *identifiers[] = {"", "allow", "observe-screensaver-extra", "Observe-screensaver"};
    for (size_t index = 0; index < sizeof(identifiers) / sizeof(identifiers[0]); index++) {
        AuthorizationMechanismRef mechanism = &engine;
        CHECK(fixture.interface->MechanismCreate(fixture.plugin,
              (AuthorizationEngineRef)&engine, identifiers[index], &mechanism) ==
              errAuthorizationInternal);
        CHECK(mechanism == NULL);
        verify_engine(engine);
    }
    CHECK(fixture.interface->PluginDestroy(fixture.plugin) == errAuthorizationSuccess);
}

static void test_repeated_invocation_and_engine_isolation(void) {
    AuthorizationCallbacks table = callbacks();
    Fixture fixture = create_fixture(&table);
    FakeEngine first = {.expected_decisions = 2, .expected_deactivations = 1};
    FakeEngine second = {.expected_decisions = 1, .expected_deactivations = 1};
    AuthorizationMechanismRef first_mechanism = create_mechanism(fixture, &first);
    AuthorizationMechanismRef second_mechanism = create_mechanism(fixture, &second);
    CHECK(first_mechanism != second_mechanism);
    CHECK(fixture.interface->MechanismInvoke(first_mechanism) == errAuthorizationSuccess);
    CHECK(first.decisions == 1 && second.decisions == 0);
    CHECK(fixture.interface->MechanismInvoke(second_mechanism) == errAuthorizationSuccess);
    CHECK(fixture.interface->MechanismDeactivate(first_mechanism) == errAuthorizationSuccess);
    CHECK(first.deactivations == 1 && second.deactivations == 0);
    CHECK(fixture.interface->MechanismInvoke(first_mechanism) == errAuthorizationSuccess);
    CHECK(fixture.interface->MechanismDeactivate(second_mechanism) == errAuthorizationSuccess);
    CHECK(fixture.interface->MechanismDestroy(second_mechanism) == errAuthorizationSuccess);
    CHECK(fixture.interface->MechanismDestroy(first_mechanism) == errAuthorizationSuccess);
    CHECK(fixture.interface->PluginDestroy(fixture.plugin) == errAuthorizationSuccess);
    verify_engine(first);
    verify_engine(second);
}

static void test_callback_errors_and_copied_callbacks(void) {
    AuthorizationCallbacks table = callbacks();
    Fixture fixture = create_fixture(&table);
    // The plug-in must retain only its two function pointers, not this table.
    table.SetResult = NULL;
    table.DidDeactivate = NULL;
    FakeEngine engine = {.expected_decisions = 1, .expected_deactivations = 1,
                         .decision_status = errAuthorizationDenied,
                         .deactivation_status = errAuthorizationCanceled};
    AuthorizationMechanismRef mechanism = create_mechanism(fixture, &engine);
    CHECK(fixture.interface->MechanismInvoke(mechanism) == errAuthorizationDenied);
    CHECK(engine.decisions == 1 && engine.deactivations == 0);
    CHECK(fixture.interface->MechanismDeactivate(mechanism) == errAuthorizationCanceled);
    CHECK(fixture.interface->MechanismDestroy(mechanism) == errAuthorizationSuccess);
    CHECK(fixture.interface->PluginDestroy(fixture.plugin) == errAuthorizationSuccess);
    verify_engine(engine);
}

static void test_base_callback_table(void) {
    for (UInt32 version = 0; version <= kAuthorizationCallbacksVersion + 1; version++) {
        AuthorizationCallbacks table = callbacks();
        table.version = version;
        // Allocate only the original prefix through DidDeactivate. An address-
        // sanitized test build detects accidental reads of the current full ABI.
        size_t size = offsetof(AuthorizationCallbacks, GetContextValue);
        AuthorizationCallbacks *prefix = malloc(size);
        CHECK(prefix != NULL);
        memcpy(prefix, &table, size);
        Fixture fixture = create_fixture(prefix);
        free(prefix);
        FakeEngine engine = {.expected_decisions = 1, .expected_deactivations = 1};
        AuthorizationMechanismRef mechanism = create_mechanism(fixture, &engine);
        CHECK(fixture.interface->MechanismInvoke(mechanism) == errAuthorizationSuccess);
        CHECK(fixture.interface->MechanismDeactivate(mechanism) == errAuthorizationSuccess);
        CHECK(fixture.interface->MechanismDestroy(mechanism) == errAuthorizationSuccess);
        CHECK(fixture.interface->PluginDestroy(fixture.plugin) == errAuthorizationSuccess);
        verify_engine(engine);
    }
}

static void test_destroy_without_invocation(void) {
    AuthorizationCallbacks table = callbacks();
    Fixture fixture = create_fixture(&table);
    FakeEngine engine = {0};
    AuthorizationMechanismRef mechanism = create_mechanism(fixture, &engine);
    CHECK(fixture.interface->MechanismDestroy(mechanism) == errAuthorizationSuccess);
    CHECK(fixture.interface->PluginDestroy(fixture.plugin) == errAuthorizationSuccess);
    verify_engine(engine);
}

typedef struct {
    // The initial member is also the engine seen by the ordinary strict fakes.
    FakeEngine engine;
    Fixture fixture;
    AuthorizationMechanismRef mechanism;
    unsigned int destructions;
} ReentrantEngine;

static void destroy_during_callback(ReentrantEngine *engine) {
    CHECK(engine->destructions == 0);
    CHECK(engine->mechanism != NULL && engine->fixture.plugin != NULL);
    CHECK(engine->fixture.interface->MechanismDestroy(engine->mechanism) ==
          errAuthorizationSuccess);
    engine->mechanism = NULL;
    // Respect the ABI: destroy the plug-in only after its sole mechanism.
    CHECK(engine->fixture.interface->PluginDestroy(engine->fixture.plugin) ==
          errAuthorizationSuccess);
    engine->fixture.plugin = NULL;
    engine->destructions++;
}

static OSStatus destroying_set_result(AuthorizationEngineRef reference,
                                      AuthorizationResult result) {
    OSStatus status = set_result(reference, result);
    destroy_during_callback((ReentrantEngine *)reference);
    return status;
}

static OSStatus destroying_did_deactivate(AuthorizationEngineRef reference) {
    OSStatus status = did_deactivate(reference);
    destroy_during_callback((ReentrantEngine *)reference);
    return status;
}

static void test_reentrant_destruction(unsigned int during_deactivation, OSStatus status) {
    AuthorizationCallbacks table = callbacks();
    if (during_deactivation) {
        table.DidDeactivate = destroying_did_deactivate;
    } else {
        table.SetResult = destroying_set_result;
    }
    ReentrantEngine engine = {
        .engine = {
            .expected_decisions = 1,
            .expected_deactivations = during_deactivation,
            .decision_status = during_deactivation ? errAuthorizationSuccess : status,
            .deactivation_status = status,
        },
        .fixture = create_fixture(&table),
    };
    engine.mechanism = create_mechanism(engine.fixture, &engine.engine);
    if (during_deactivation) {
        CHECK(engine.fixture.interface->MechanismInvoke(engine.mechanism) ==
              errAuthorizationSuccess);
        CHECK(engine.engine.decisions == 1 && engine.destructions == 0);
        CHECK(engine.fixture.interface->MechanismDeactivate(engine.mechanism) == status);
    } else {
        CHECK(engine.fixture.interface->MechanismInvoke(engine.mechanism) == status);
    }
    // The callback freed both heap objects before Invoke/Deactivate returned.
    // ASan catches any implementation access to either object after that point.
    CHECK(engine.destructions == 1);
    CHECK(engine.mechanism == NULL && engine.fixture.plugin == NULL);
    verify_engine(engine.engine);
}

int main(void) {
    test_required_callbacks();
    test_unknown_mechanism();
    test_repeated_invocation_and_engine_isolation();
    test_callback_errors_and_copied_callbacks();
    test_base_callback_table();
    test_destroy_without_invocation();
    test_reentrant_destruction(0, errAuthorizationSuccess);
    test_reentrant_destruction(0, errAuthorizationInternal);
    test_reentrant_destruction(1, errAuthorizationSuccess);
    test_reentrant_destruction(1, errAuthorizationInternal);
    puts("AuthorizationProbe fake-engine tests passed");
    return 0;
}
