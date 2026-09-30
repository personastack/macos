// Strict in-process fakes. These tests never request an OS right or display activity.
#include "ProbeActions.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "check failed at line %d: %s\n", __LINE__, #condition); abort(); \
} } while (0)

typedef struct {
    unsigned int authorization_calls, wait_calls, activity_calls, release_calls;
    unsigned int expected_authorization, expected_wait, expected_activity, expected_release;
    unsigned int delay;
    IOPMUserActiveType type;
    IOPMAssertionID identifier;
    OSStatus authorization_status;
    int wait_status;
    IOReturn activity_status, release_status;
} Fake;
static Fake fake;

// Link these API fakes into this test executable instead of calling authd.
typedef struct {
    unsigned int creates, copies, frees, stage;
    OSStatus create_status, copy_status, free_status;
} AuthorizationFake;
static AuthorizationFake authorization_fake;

OSStatus AuthorizationCreate(const AuthorizationRights *rights,
                             const AuthorizationEnvironment *environment,
                             AuthorizationFlags flags, AuthorizationRef *authorization) {
    CHECK(authorization_fake.stage++ == 0);
    CHECK(++authorization_fake.creates == 1);
    CHECK(rights == NULL && environment == kAuthorizationEmptyEnvironment);
    CHECK(flags == kAuthorizationFlagDefaults && *authorization == NULL);
    if (authorization_fake.create_status == errAuthorizationSuccess)
        *authorization = (AuthorizationRef)&authorization_fake;
    return authorization_fake.create_status;
}

OSStatus AuthorizationCopyRights(AuthorizationRef authorization, const AuthorizationRights *rights,
                                 const AuthorizationEnvironment *environment,
                                 AuthorizationFlags flags, AuthorizationRights **authorized_rights) {
    CHECK(authorization_fake.stage++ == 1);
    CHECK(++authorization_fake.copies == 1);
    CHECK(authorization == (AuthorizationRef)&authorization_fake);
    CHECK(environment == kAuthorizationEmptyEnvironment && authorized_rights == NULL);
    CHECK(flags == kAuthorizationFlagExtendRights);
    CHECK(rights->count == 1 && rights->items != NULL);
    CHECK(strcmp(rights->items[0].name, "ai.personastack.locked-session-probe") == 0);
    CHECK(rights->items[0].valueLength == 0 && rights->items[0].value == NULL);
    CHECK(rights->items[0].flags == 0);
    return authorization_fake.copy_status;
}

OSStatus AuthorizationFree(AuthorizationRef authorization, AuthorizationFlags flags) {
    CHECK(authorization_fake.stage++ == 2);
    CHECK(++authorization_fake.frees == 1);
    CHECK(authorization == (AuthorizationRef)&authorization_fake);
    CHECK(flags == kAuthorizationFlagDestroyRights);
    return authorization_fake.free_status;
}

static OSStatus authorize(void) {
    CHECK(++fake.authorization_calls == fake.expected_authorization);
    return fake.authorization_status;
}
static int wait_seconds(unsigned int seconds) {
    CHECK(++fake.wait_calls == fake.expected_wait);
    CHECK(seconds == fake.delay && fake.activity_calls == 0);
    return fake.wait_status;
}
static IOReturn activity(IOPMUserActiveType type, IOPMAssertionID *identifier) {
    CHECK(++fake.activity_calls == fake.expected_activity);
    CHECK(fake.wait_calls == 1 && fake.authorization_calls == 0);
    CHECK(type == fake.type && *identifier == kIOPMNullAssertionID);
    *identifier = fake.identifier;
    return fake.activity_status;
}
static IOReturn release(IOPMAssertionID identifier) {
    CHECK(++fake.release_calls == fake.expected_release);
    CHECK(fake.activity_calls == 1 && identifier == fake.identifier);
    CHECK(identifier != kIOPMNullAssertionID);
    return fake.release_status;
}
static ProbeHooks hooks(void) {
    return (ProbeHooks){.authorize = authorize, .wait = wait_seconds,
                        .activity = activity, .release = release};
}
static void verify(void) {
    CHECK(fake.authorization_calls == fake.expected_authorization);
    CHECK(fake.wait_calls == fake.expected_wait);
    CHECK(fake.activity_calls == fake.expected_activity);
    CHECK(fake.release_calls == fake.expected_release);
}

static void test_parser(void) {
    ProbeOptions options;
    const char *help[] = {"probe"};
    CHECK(probe_parse(1, help, &options) && options.action == ProbeHelp);
    const char *authorization[] = {"probe", "--validate-plugin", "--dedicated-mac"};
    CHECK(probe_parse(3, authorization, &options) && options.action == ProbeAuthorization);
    const char *remote[] = {"probe", "--remote-activity-after", "20", "--dedicated-mac"};
    CHECK(probe_parse(4, remote, &options) && options.action == ProbeRemoteActivity && options.delay == 20);
    const char *local[] = {"probe", "--local-activity-after", "60", "--dedicated-mac"};
    CHECK(probe_parse(4, local, &options) && options.action == ProbeLocalActivity && options.delay == 60);
    const char *bad_delays[] = {"", "0", "61", "-1", "+1", " 1", "1 ", "1.5", "1s", "999999999999999999999"};
    for (size_t index = 0; index < sizeof(bad_delays) / sizeof(bad_delays[0]); index++) {
        const char *bad[] = {"probe", "--remote-activity-after", bad_delays[index], "--dedicated-mac"};
        CHECK(!probe_parse(4, bad, &options));
        CHECK(options.action == ProbeHelp);
    }
    const char *bad_ack[] = {"probe", "--remote-activity-after", "1", "--another-mac"};
    CHECK(!probe_parse(4, bad_ack, &options));
    CHECK(!probe_parse(3, remote, &options));
    CHECK(!probe_parse(2, authorization, &options));
    const char *extra[] = {"probe", "--validate-plugin", "--dedicated-mac", "extra"};
    CHECK(!probe_parse(4, extra, &options));
    const char *unknown[] = {"probe", "--unlock", "1", "--dedicated-mac"};
    CHECK(!probe_parse(4, unknown, &options));
}

static void test_no_action(void) {
    fake = (Fake){0};
    CHECK(probe_run((ProbeOptions){.action = ProbeHelp}, hooks()) == 0);
    CHECK(probe_run((ProbeOptions){.action = 99, .delay = 1}, hooks()) == 2);
    CHECK(probe_run((ProbeOptions){.action = ProbeRemoteActivity, .delay = 61}, hooks()) == 2);
    verify();
}

static void test_authorization(void) {
    OSStatus statuses[] = {errAuthorizationDenied, errAuthorizationSuccess,
                           errAuthorizationInternal, errAuthorizationCanceled};
    for (size_t index = 0; index < sizeof(statuses) / sizeof(statuses[0]); index++) {
        fake = (Fake){.expected_authorization = 1, .authorization_status = statuses[index]};
        CHECK(probe_run((ProbeOptions){.action = ProbeAuthorization}, hooks()) ==
              (statuses[index] == errAuthorizationDenied ? 0 : 1));
        verify();
    }
}

static void test_actual_right_request_and_cleanup(void) {
    // These tests own process-local fake API state. There is no system authorization call.
    authorization_fake = (AuthorizationFake){.create_status = errAuthorizationInternal};
    CHECK(probe_authorize_diagnostic() == errAuthorizationInternal);
    CHECK(authorization_fake.creates == 1 && authorization_fake.copies == 0 && authorization_fake.frees == 0);
    OSStatus statuses[] = {errAuthorizationDenied, errAuthorizationSuccess,
                           errAuthorizationInternal, errAuthorizationCanceled};
    for (size_t index = 0; index < sizeof(statuses) / sizeof(statuses[0]); index++) {
        for (int cleanup_fails = 0; cleanup_fails <= 1; cleanup_fails++) {
            authorization_fake = (AuthorizationFake){
                .copy_status = statuses[index],
                .free_status = cleanup_fails ? errAuthorizationInvalidRef : errAuthorizationSuccess};
            CHECK(probe_authorize_diagnostic() ==
                  (cleanup_fails ? errAuthorizationInvalidRef : statuses[index]));
            CHECK(authorization_fake.creates == 1 && authorization_fake.copies == 1 && authorization_fake.frees == 1);
        }
    }
}

static void test_activity(void) {
    for (int local = 0; local <= 1; local++) {
        for (int failure = 0; failure < 5; failure++) {
            fake = (Fake){.expected_wait = 1, .expected_activity = 1,
                .expected_release = 1, .delay = 1,
                .type = local ? kIOPMUserActiveLocal : kIOPMUserActiveRemote, .identifier = 71};
            if (failure == 1) {
                fake.wait_status = -1; fake.expected_activity = 0; fake.expected_release = 0;
            }
            if (failure == 2) {
                fake.activity_status = kIOReturnError; fake.expected_release = 0;
            }
            if (failure == 3) { fake.identifier = kIOPMNullAssertionID; fake.expected_release = 0; }
            if (failure == 4) fake.release_status = kIOReturnError;
            CHECK(probe_run((ProbeOptions){.action = local ? ProbeLocalActivity : ProbeRemoteActivity,
                           .delay = 1}, hooks()) == (failure == 0 ? 0 : 1));
            verify();
        }
    }
}

int main(void) {
    test_parser(); test_no_action(); test_authorization(); test_actual_right_request_and_cleanup(); test_activity();
    puts("ProbeActions strict-fake tests passed");
    return 0;
}
