#include "OKMPVBridge.h"

#include <stdio.h>

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
    printf(
        "OKMPVBridge smoke passed (client API %s, event size %d)\n",
        okmpv_client_api_version_string(),
        okmpv_event_size()
    );
    okmpv_destroy(client);
    return 0;
}
