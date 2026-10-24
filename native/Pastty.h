#ifndef PASTTY_NATIVE_H
#define PASTTY_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
char *pastty_list(void);
void pastty_free_string(char *value);
int pastty_capture(const unsigned char *data, size_t len, const char *uti,
                   const unsigned char *thumbnail, size_t thumbnail_len);
int pastty_load(int64_t id, unsigned char **data, size_t *len, char **uti);
void pastty_free_data(unsigned char *data, size_t len);
int pastty_get_bool(const char *key, int default_value);
int pastty_set_bool(const char *key, int value);
char *pastty_get_hotkey(void);
int pastty_set_hotkey(uint32_t keycode, uint32_t modifiers);
int pastty_run(void);
void pastty_reopen_existing(void);
#ifdef __cplusplus
}
#endif
#endif
