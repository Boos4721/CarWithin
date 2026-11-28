#ifndef TDS_CAR_KIT_CRYPTO_H
#define TDS_CAR_KIT_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
int tds_car_kit_aes_ctr(const uint8_t key[16], const uint8_t iv[16], const uint8_t *input, size_t count, uint8_t *output);
int tds_dl_make_key(uint8_t private_key[32], uint8_t public_key[64]);
int tds_dl_public_key(const uint8_t private_key[32], uint8_t public_key[64]);
int tds_dl_valid_public_key(const uint8_t public_key[64]);
int tds_dl_shared_secret(const uint8_t private_key[32], const uint8_t public_key[64], uint8_t secret[32]);
int tds_dl_aes_cbc(int encrypt, const uint8_t key[16], const uint8_t iv[16], const uint8_t *input, size_t count, uint8_t *output);
#endif
