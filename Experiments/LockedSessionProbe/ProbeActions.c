// Dedicated-Mac diagnostics. No installer, unlock, input injection or policy writes.
#include "ProbeActions.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

static void usage(void) {
    puts("PersonaStack locked-session diagnostic (never authorizes an unlock)\n"
         "  --help\n"
         "  --validate-plugin --dedicated-mac\n"
         "  --remote-activity-after SECONDS --dedicated-mac\n"
         "  --local-activity-after SECONDS --dedicated-mac\n"
         "SECONDS must be a decimal integer from 1 through 60.\n"
         "Read README.md before installing or changing policy on a dedicated test Mac.");
}

static int parse_delay(const char *input, unsigned int *delay) {
    if (*input == '\0') return 0;
    unsigned int value = 0;
    for (const char *position = input; *position != '\0'; position++) {
        if (*position < '0' || *position > '9') return 0;
        value = value * 10 + (unsigned int)(*position - '0');
        if (value > 60) return 0;
    }
    if (value == 0) return 0;
    *delay = value;
    return 1;
}

int probe_parse(int argc, const char *const *argv, ProbeOptions *options) {
    *options = (ProbeOptions){.action = ProbeHelp};
    if (argc == 1 || (argc == 2 && strcmp(argv[1], "--help") == 0)) return 1;
    if (argc == 3 && strcmp(argv[1], "--validate-plugin") == 0 &&
        strcmp(argv[2], "--dedicated-mac") == 0) {
        options->action = ProbeAuthorization;
        return 1;
    }
    if (argc != 4 || strcmp(argv[3], "--dedicated-mac") != 0) return 0;
    ProbeAction action;
    if (strcmp(argv[1], "--remote-activity-after") == 0) action = ProbeRemoteActivity;
    else if (strcmp(argv[1], "--local-activity-after") == 0) action = ProbeLocalActivity;
    else return 0;
    unsigned int delay = 0;
    if (!parse_delay(argv[2], &delay)) return 0;
    *options = (ProbeOptions){.action = action, .delay = delay};
    return 1;
}

int probe_run(ProbeOptions options, ProbeHooks hooks) {
    printf("probe_build_id=%s\n", probe_build_id());
    if (options.action == ProbeHelp) {
        usage();
        return 0;
    }
    if (options.action == ProbeAuthorization) {
        OSStatus status = hooks.authorize();
        printf("diagnostic_authorization_status=%d\n", (int)status);
        puts("Denial alone does not prove plug-in loading. Verify its trusted-host log before proceeding.");
        return status == errAuthorizationDenied ? 0 : 1;
    }
    if ((options.action != ProbeRemoteActivity && options.action != ProbeLocalActivity) ||
        options.delay == 0 || options.delay > 60) return 2;
    printf("activity_delay_seconds=%u\n", options.delay);
    fflush(stdout);
    if (hooks.wait(options.delay) != 0) {
        puts("wait_interrupted; no activity requested");
        return 1;
    }
    IOPMUserActiveType type = options.action == ProbeRemoteActivity ?
        kIOPMUserActiveRemote : kIOPMUserActiveLocal;
    IOPMAssertionID identifier = kIOPMNullAssertionID;
    IOReturn status = hooks.activity(type, &identifier);
    printf("activity_status=0x%x\n", (unsigned int)status);
    if (status != kIOReturnSuccess) return 1;
    if (identifier == kIOPMNullAssertionID) {
        puts("activity_returned_no_owned_assertion");
        return 1;
    }
    IOReturn release_status = hooks.release(identifier);
    printf("assertion_release_status=0x%x\n", (unsigned int)release_status);
    puts("Display activity is not unlock evidence. Check actual screensaver mechanism invocation.");
    return release_status == kIOReturnSuccess ? 0 : 1;
}

OSStatus probe_authorize_diagnostic(void) {
    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                         kAuthorizationFlagDefaults, &authorization);
    if (status != errAuthorizationSuccess) return status;
    AuthorizationItem item = {.name = PROBE_RIGHT};
    AuthorizationRights rights = {.count = 1, .items = &item};
    status = AuthorizationCopyRights(authorization, &rights, kAuthorizationEmptyEnvironment,
                                    kAuthorizationFlagExtendRights, NULL);
    OSStatus cleanup = AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
    return cleanup == errAuthorizationSuccess ? status : cleanup;
}

#ifndef PROBE_TEST
static int wait_seconds(unsigned int seconds) {
    struct timespec delay = {.tv_sec = (time_t)seconds};
    // Interrupted trials stop. No retry or unexpected later activity.
    return nanosleep(&delay, NULL);
}

static IOReturn declare_activity(IOPMUserActiveType type, IOPMAssertionID *identifier) {
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return kIOReturnError;
    printf("activity_type=%s\nactivity_started_unix=%lld.%09ld\n",
           type == kIOPMUserActiveRemote ? "remote" : "local",
           (long long)now.tv_sec, now.tv_nsec);
    fflush(stdout);
    IOReturn status = IOPMAssertionDeclareUserActivity(CFSTR("PersonaStack dedicated-Mac diagnostic"),
                                                     type, identifier);
    if (clock_gettime(CLOCK_REALTIME, &now) == 0) {
        printf("activity_returned_unix=%lld.%09ld\n", (long long)now.tv_sec, now.tv_nsec);
    }
    return status;
}

int main(int argc, const char *argv[]) {
    ProbeOptions options;
    if (!probe_parse(argc, argv, &options)) {
        usage();
        return 2;
    }
    return probe_run(options, (ProbeHooks){.authorize = probe_authorize_diagnostic,
                     .wait = wait_seconds, .activity = declare_activity,
                     .release = IOPMAssertionRelease});
}
#endif
