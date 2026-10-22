#ifndef MOMOFAN_CSMC_H
#define MOMOFAN_CSMC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CSMCConnection CSMCConnection;

typedef struct {
    int32_t code;
    uint32_t kernelCode;
    uint32_t key;
    uint8_t smcResult;
    uint8_t smcStatus;
    uint8_t command;
} CSMCError;

typedef struct {
    uint32_t size;
    uint32_t dataType;
    uint8_t attributes;
} CSMCKeyInfo;

typedef struct {
    CSMCKeyInfo info;
    uint8_t bytes[32];
} CSMCValue;

// FourCC values are packed with the first ASCII character in bits 31...24.
// A connection serializes its IOKit calls and caches successful key metadata.
CSMCConnection *CSMCOpen(CSMCError *error);
void CSMCClose(CSMCConnection *connection);
int32_t CSMCGetKeyInfo(CSMCConnection *connection, uint32_t key,
                       CSMCKeyInfo *info, CSMCError *error);
int32_t CSMCRead(CSMCConnection *connection, uint32_t key,
                 CSMCValue *value, CSMCError *error);

// Writes are restricted to per-fan F[0-9]md / F[0-9]Md / F[0-9]Tg keys.
// No unlock key, arbitrary SMC command, fan minimum or maximum can be written.
// Caller must validate the target against freshly read hardware limits.
int32_t CSMCWrite(CSMCConnection *connection, uint32_t key,
                  const uint8_t *bytes, uint32_t size, CSMCError *error);

#ifdef __cplusplus
}
#endif
#endif
