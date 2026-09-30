#ifndef PERSONASTACK_PROBE_ACTIONS_H
#define PERSONASTACK_PROBE_ACTIONS_H

#include <Security/Authorization.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

#define PROBE_RIGHT "ai.personastack.locked-session-probe"

typedef enum { ProbeHelp, ProbeAuthorization, ProbeRemoteActivity, ProbeLocalActivity } ProbeAction;
typedef struct { ProbeAction action; unsigned int delay; } ProbeOptions;
typedef struct {
    OSStatus (*authorize)(void);
    int (*wait)(unsigned int seconds);
    IOReturn (*activity)(IOPMUserActiveType type, IOPMAssertionID *identifier);
    IOReturn (*release)(IOPMAssertionID identifier);
} ProbeHooks;

int probe_parse(int argc, const char *const *argv, ProbeOptions *options);
int probe_run(ProbeOptions options, ProbeHooks hooks);
OSStatus probe_authorize_diagnostic(void);

#endif
