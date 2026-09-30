#ifndef PERSONASTACK_PROBE_IDENTITY_H
#define PERSONASTACK_PROBE_IDENTITY_H

#ifndef PROBE_BUILD_ID
#error Build the diagnostic through build.sh to bind its source identity
#endif

static inline const char *probe_build_id(void) { return PROBE_BUILD_ID; }

#endif
