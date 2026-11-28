// micro-ecc v1.1, BSD-2-Clause. See Vendor/micro-ecc/LICENSE.txt.
// Only secp256k1, portable C; public APIs keep network byte order.
#include "TDSCarKitCrypto.h"
#if defined(__APPLE__)
#include <Security/SecRandom.h>
#endif
#define uECC_SUPPORTS_secp160r1 0
#define uECC_SUPPORTS_secp192r1 0
#define uECC_SUPPORTS_secp224r1 0
#define uECC_SUPPORTS_secp256r1 0
#define uECC_SUPPORTS_secp256k1 1
#define uECC_SUPPORT_COMPRESSED_POINT 0
#define uECC_PLATFORM 0
// Use the platform CSPRNG for key generation and multiplication blinding.
#if defined(__APPLE__)
#define _UECC_PLATFORM_SPECIFIC_H_
static int default_RNG(uint8_t *out, unsigned size) {
    return SecRandomCopyBytes(kSecRandomDefault, size, out) == errSecSuccess;
}
#define default_RNG_defined 1
#endif
#include "Vendor/micro-ecc/uECC.inc"
int tds_dl_make_key(uint8_t private_key[32], uint8_t public_key[64]) {
    return uECC_make_key(public_key, private_key, uECC_secp256k1());
}
int tds_dl_public_key(const uint8_t private_key[32], uint8_t public_key[64]) {
    return uECC_compute_public_key(private_key, public_key, uECC_secp256k1());
}
int tds_dl_valid_public_key(const uint8_t public_key[64]) {
    return uECC_valid_public_key(public_key, uECC_secp256k1());
}
int tds_dl_shared_secret(const uint8_t private_key[32], const uint8_t public_key[64], uint8_t secret[32]) {
    if (!tds_dl_valid_public_key(public_key)) return 0;
    return uECC_shared_secret(public_key, private_key, secret, uECC_secp256k1());
}
