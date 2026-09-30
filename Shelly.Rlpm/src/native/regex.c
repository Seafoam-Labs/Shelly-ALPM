/* regex_t contains implementation-specific bitfields that translate-c treats
 * as opaque. Keep allocation and destruction in C; policy/search stay in Zig. */
#include <regex.h>
#include <stdlib.h>

int rlpm_regex_create(const char *pattern, regex_t **out) {
    regex_t *regex = malloc(sizeof(*regex));
    if (!regex)
        return REG_ESPACE;
    int status = regcomp(regex, pattern, REG_EXTENDED | REG_NOSUB | REG_ICASE | REG_NEWLINE);
    if (status) {
        free(regex);
        return status;
    }
    *out = regex;
    return 0;
}

void rlpm_regex_destroy(regex_t *regex) {
    regfree(regex);
    free(regex);
}
