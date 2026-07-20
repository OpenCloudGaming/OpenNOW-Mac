#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PASSWORD_LIMIT 4096

struct credentials {
    const char *password;
};

static int conversation(int message_count, const struct pam_message **messages, struct pam_response **responses, void *appdata_ptr) {
    struct credentials *credentials = (struct credentials *)appdata_ptr;
    struct pam_response *reply = calloc((size_t)message_count, sizeof(struct pam_response));
    if (reply == NULL) return PAM_CONV_ERR;

    for (int index = 0; index < message_count; index++) {
        switch (messages[index]->msg_style) {
            case PAM_PROMPT_ECHO_OFF:
                reply[index].resp = strdup(credentials->password);
                if (reply[index].resp == NULL) {
                    for (int cleanup = 0; cleanup < index; cleanup++) free(reply[cleanup].resp);
                    free(reply);
                    return PAM_CONV_ERR;
                }
                break;
            case PAM_PROMPT_ECHO_ON:
            case PAM_ERROR_MSG:
            case PAM_TEXT_INFO:
                reply[index].resp = NULL;
                break;
            default:
                for (int cleanup = 0; cleanup < index; cleanup++) free(reply[cleanup].resp);
                free(reply);
                return PAM_CONV_ERR;
        }
    }

    *responses = reply;
    return PAM_SUCCESS;
}

static int valid_username(const char *username) {
    size_t length = strlen(username);
    if (length == 0 || length > 128) return 0;
    for (size_t index = 0; index < length; index++) {
        char character = username[index];
        if ((character >= 'A' && character <= 'Z') ||
            (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') ||
            character == '.' || character == '_' || character == '-' || character == '@') continue;
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2 || !valid_username(argv[1])) return 2;

    char password[PASSWORD_LIMIT + 1];
    ssize_t bytes_read = read(STDIN_FILENO, password, PASSWORD_LIMIT);
    if (bytes_read <= 0) return 1;
    password[bytes_read] = '\0';
    while (bytes_read > 0 && (password[bytes_read - 1] == '\n' || password[bytes_read - 1] == '\r')) {
        password[bytes_read - 1] = '\0';
        bytes_read--;
    }

    struct credentials credentials = { .password = password };
    struct pam_conv conv = { .conv = conversation, .appdata_ptr = &credentials };
    pam_handle_t *handle = NULL;
    int status = pam_start("macforce-now-remote-coop", argv[1], &conv, &handle);
    if (status == PAM_SUCCESS) status = pam_authenticate(handle, 0);
    if (status == PAM_SUCCESS) status = pam_acct_mgmt(handle, 0);
    if (handle != NULL) pam_end(handle, status);

    memset(password, 0, sizeof(password));
    return status == PAM_SUCCESS ? 0 : 1;
}
