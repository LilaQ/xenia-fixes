/* RB3 base executable 88E6DC86853C2522 only.
 * Replace its missing XeKeys calls with software AES, following the
 * RB3Enhanced crypto-hook behavior. Original song-key material is supplied
 * locally by the patch generator and is not stored in this repository.
 */
#include <stddef.h>
#include <stdint.h>
#include "aes.h"

#define GAME_KEYSET_BASE 0x82c45af0U
#define LOCAL_KEYSET_BASE 0x82c2e000U

static uint8_t selected_keys[8][16];
static uint8_t feeds[8][16];

void *memcpy(void *destination, const void *source, size_t size) {
    uint8_t *out = destination;
    const uint8_t *in = source;
    for (size_t i = 0; i < size; ++i) out[i] = in[i];
    return destination;
}

__attribute__((section(".text.entry_set")))
uint32_t rb3_set_key(uint32_t slot, const uint8_t *game_key, uint32_t length) {
    uint32_t index = slot - 0xe0U;
    uintptr_t offset = (uintptr_t)game_key - GAME_KEYSET_BASE;
    if (index >= 8 || length != 16 || offset > 48 || (offset & 15))
        return 0xc8000003U;
    const volatile uint8_t *keys = (const volatile uint8_t *)LOCAL_KEYSET_BASE;
    for (uint32_t i = 0; i < 16; ++i) {
        selected_keys[index][i] = keys[offset + i];
        feeds[index][i] = 0;
    }
    return 0;
}

__attribute__((section(".text.entry_cbc")))
uint32_t rb3_aes_cbc(uint32_t slot, const uint8_t *input, uint32_t length,
                     uint8_t *output, uint8_t *iv, uint32_t encrypt) {
    uint32_t index = slot - 0xe0U;
    if (index >= 8 || !input || !output || (length & 15))
        return 0xc8000003U;
    struct AES_ctx ctx;
    /* The RB3 wrapper supplies no IV and decrypts one 16-byte block.
       Preserve the feed between CBC calls; SetKey resets it. */
    uint8_t *feed = iv ? iv : feeds[index];
    AES_init_ctx_iv(&ctx, selected_keys[index], feed);
    if (input != output) memcpy(output, input, length);
    if (encrypt) AES_CBC_encrypt_buffer(&ctx, output, length);
    else AES_CBC_decrypt_buffer(&ctx, output, length);
    memcpy(feed, ctx.Iv, 16);
    return 0;
}
