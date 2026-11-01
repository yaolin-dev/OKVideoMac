#include "OKMPVBridge.h"

#include <stdio.h>
#include <string.h>
#include <stdatomic.h>

static void event_wakeup(void *context) {
    atomic_fetch_add((_Atomic int *)context, 1);
}

int main(void) {
    OKMPVClient *client = okmpv_create();
    if (client == NULL) {
        fprintf(stderr, "okmpv_create failed\n");
        return 1;
    }
    if (okmpv_set_option_string(client, "config", "no") < 0 ||
        okmpv_set_option_string(client, "terminal", "no") < 0 ||
        okmpv_set_option_string(client, "vo", "null") < 0 ||
        okmpv_initialize(client) < 0) {
        fprintf(stderr, "okmpv initialization failed\n");
        okmpv_destroy(client);
        return 1;
    }
    const char *headers[] = {
        "User-Agent: OKVideoMac-Bridge-Smoke"
    };
    _Atomic int wakeups = 0;
    okmpv_set_wakeup_callback(client, event_wakeup, &wakeups);
    okmpv_wakeup(client);
    if (atomic_load(&wakeups) == 0) return 6;
    if (okmpv_request_log_messages(client, "warn") < 0) return 2;
    // A rejected command produces a native error without network or media.
    const char *invalid[] = {"OKVIDEOMAC_DIAGNOSTIC_CANARY_INVALID_COMMAND"};
    if (okmpv_command(client, 1, invalid) >= 0) return 3;
    int saw_log = 0;
    for (int index = 0; index < 50; index++) {
        OKMPVEvent event;
        if (okmpv_wait_event(client, 0.01, &event) < 0) return 4;
        if (event.event_id == 2 && event.property_name != NULL &&
            event.string_value != NULL && event.property_format > 0 &&
            strstr(event.string_value, "OKVIDEOMAC_DIAGNOSTIC_CANARY") != NULL) {
            saw_log = 1;
            break;
        }
    }
    if (!saw_log || okmpv_request_log_messages(client, "no") < 0) return 5;
    if (okmpv_set_property_string_array(
            client,
            "http-header-fields",
            1,
            headers
        ) < 0) {
        fprintf(stderr, "structured header assignment failed\n");
        okmpv_destroy(client);
        return 1;
    }
    const char *command[] = {"stop"};
    if (okmpv_command(client, 1, command) < 0) {
        fprintf(stderr, "structured command failed\n");
        okmpv_destroy(client);
        return 1;
    }
    okmpv_set_wakeup_callback(client, NULL, NULL);
    int detached_wakeups = atomic_load(&wakeups);
    okmpv_wakeup(client);
    if (atomic_load(&wakeups) != detached_wakeups) return 7;
    printf(
        "OKMPVBridge smoke passed (client API %s, event size %d)\n",
        okmpv_client_api_version_string(),
        okmpv_event_size()
    );
    okmpv_destroy(client);
    return 0;
}
