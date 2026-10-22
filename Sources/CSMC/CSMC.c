// AppleSMC protocol layout, independently implemented and checked on Mac17,8.
// Protocol references and MIT notices: ../../../hardware/NOTES.md.
#include "CSMC.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCPLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPLimit limit;
    SMCKeyInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMCMessage;

_Static_assert(sizeof(SMCMessage) == 80, "AppleSMC message size");
_Static_assert(offsetof(SMCMessage, info) == 28, "AppleSMC keyInfo offset");
_Static_assert(offsetof(SMCMessage, result) == 40, "AppleSMC result offset");
_Static_assert(offsetof(SMCMessage, command) == 42, "AppleSMC command offset");
_Static_assert(offsetof(SMCMessage, index) == 44, "AppleSMC data32 offset");
_Static_assert(offsetof(SMCMessage, bytes) == 48, "AppleSMC payload offset");

enum { SMCRead = 5, SMCWrite = 6, SMCInfo = 9 };
enum { ErrorArgument = 1, ErrorAllocation = 2, ErrorService = 3,
       ErrorKernel = 4, ErrorSMC = 5, ErrorProtocol = 6 };
typedef struct { uint32_t key; SMCKeyInfo info; } CacheEntry;
struct CSMCConnection {
    io_connect_t port;
    pthread_mutex_t mutex;
    CacheEntry *cache;
    size_t count, capacity;
};

static int32_t fail(CSMCError *error, int32_t code, uint32_t kernel,
                    uint32_t key, uint8_t command, uint8_t result, uint8_t status) {
    if (error) {
        memset(error, 0, sizeof(*error));
        error->code = code; error->kernelCode = kernel; error->key = key;
        error->command = command; error->smcResult = result; error->smcStatus = status;
    }
    return code;
}

static void clearError(CSMCError *error) { if (error) memset(error, 0, sizeof(*error)); }

// Called with the connection mutex held. Inspect BOTH the kernel and SMC result.
static int32_t call(CSMCConnection *connection, const SMCMessage *input,
                    SMCMessage *output, CSMCError *error) {
    memset(output, 0, sizeof(*output));
    size_t outputSize = sizeof(*output);
    kern_return_t kr = IOConnectCallStructMethod(connection->port, 2,
        input, sizeof(*input), output, &outputSize);
    if (kr != KERN_SUCCESS)
        return fail(error, ErrorKernel, (uint32_t)kr, input->key, input->command,
                    output->result, output->status);
    if (outputSize != sizeof(*output))
        return fail(error, ErrorProtocol, kIOReturnUnderrun, input->key,
                    input->command, output->result, output->status);
    if (output->result != 0)
        return fail(error, ErrorSMC, 0, input->key, input->command,
                    output->result, output->status);
    return 0;
}

static int32_t keyInfo(CSMCConnection *connection, uint32_t key,
                       SMCKeyInfo *info, CSMCError *error) {
    for (size_t i = 0; i < connection->count; i++) {
        if (connection->cache[i].key == key) { *info = connection->cache[i].info; return 0; }
    }
    SMCMessage input = {0}, output;
    input.key = key; input.command = SMCInfo;
    int32_t rc = call(connection, &input, &output, error);
    if (rc) return rc;
    if (output.info.size == 0 || output.info.size > 32)
        return fail(error, ErrorProtocol, kIOReturnBadArgument, key, SMCInfo, 0, 0);
    *info = output.info;
    if (connection->count == connection->capacity) {
        size_t capacity = connection->capacity ? connection->capacity * 2 : 32;
        if (capacity <= 4096) {
            CacheEntry *cache = realloc(connection->cache, capacity * sizeof(*cache));
            if (cache) { connection->cache = cache; connection->capacity = capacity; }
        }
    }
    // Allocation failure only disables caching; a successful hardware read remains valid.
    if (connection->count < connection->capacity)
        connection->cache[connection->count++] = (CacheEntry){ key, *info };
    return 0;
}

CSMCConnection *CSMCOpen(CSMCError *error) {
    clearError(error);
    CSMCConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) { fail(error, ErrorAllocation, kIOReturnNoMemory, 0, 0, 0, 0); return NULL; }
    if (pthread_mutex_init(&connection->mutex, NULL)) {
        fail(error, ErrorAllocation, kIOReturnNoResources, 0, 0, 0, 0); free(connection); return NULL;
    }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) {
        fail(error, ErrorService, kIOReturnNotFound, 0, 0, 0, 0);
        pthread_mutex_destroy(&connection->mutex); free(connection); return NULL;
    }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connection->port);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        fail(error, ErrorKernel, (uint32_t)kr, 0, 0, 0, 0);
        pthread_mutex_destroy(&connection->mutex); free(connection); return NULL;
    }
    return connection;
}

void CSMCClose(CSMCConnection *connection) {
    if (!connection) return;
    // The owner must retain the connection for the duration of each public call.
    pthread_mutex_lock(&connection->mutex);
    IOServiceClose(connection->port);
    free(connection->cache);
    pthread_mutex_unlock(&connection->mutex);
    pthread_mutex_destroy(&connection->mutex);
    free(connection);
}

int32_t CSMCGetKeyInfo(CSMCConnection *connection, uint32_t key,
                       CSMCKeyInfo *info, CSMCError *error) {
    clearError(error);
    if (info) memset(info, 0, sizeof(*info));
    if (!connection || !info) return fail(error, ErrorArgument, kIOReturnBadArgument, key, SMCInfo, 0, 0);
    pthread_mutex_lock(&connection->mutex);
    SMCKeyInfo raw = {0};
    int32_t rc = keyInfo(connection, key, &raw, error);
    if (!rc) { info->size = raw.size; info->dataType = raw.type; info->attributes = raw.attributes; }
    pthread_mutex_unlock(&connection->mutex);
    return rc;
}

int32_t CSMCRead(CSMCConnection *connection, uint32_t key,
                 CSMCValue *value, CSMCError *error) {
    clearError(error);
    if (value) memset(value, 0, sizeof(*value));
    if (!connection || !value) return fail(error, ErrorArgument, kIOReturnBadArgument, key, SMCRead, 0, 0);
    pthread_mutex_lock(&connection->mutex);
    SMCKeyInfo info = {0};
    int32_t rc = keyInfo(connection, key, &info, error);
    if (!rc) {
        SMCMessage input = {0}, output;
        input.key = key; input.command = SMCRead; input.info.size = info.size;
        rc = call(connection, &input, &output, error);
        if (!rc) {
            value->info.size = info.size; value->info.dataType = info.type; value->info.attributes = info.attributes;
            memcpy(value->bytes, output.bytes, info.size);
        }
    }
    pthread_mutex_unlock(&connection->mutex);
    return rc;
}

static int writableFanKey(uint32_t key) {
    uint8_t a = (uint8_t)(key >> 24), b = (uint8_t)(key >> 16);
    uint8_t c = (uint8_t)(key >> 8), d = (uint8_t)key;
    return a == 'F' && b >= '0' && b <= '9' &&
        (((c == 'm' || c == 'M') && d == 'd') || (c == 'T' && d == 'g'));
}

int32_t CSMCWrite(CSMCConnection *connection, uint32_t key,
                  const uint8_t *bytes, uint32_t size, CSMCError *error) {
    clearError(error);
    if (!connection || !bytes || size == 0 || size > 32 || !writableFanKey(key))
        return fail(error, ErrorArgument, kIOReturnBadArgument, key, SMCWrite, 0, 0);
    pthread_mutex_lock(&connection->mutex);
    SMCKeyInfo info = {0};
    int32_t rc = keyInfo(connection, key, &info, error);
    if (!rc && size != info.size)
        rc = fail(error, ErrorArgument, kIOReturnBadArgument, key, SMCWrite, 0, 0);
    if (!rc) {
        SMCMessage input = {0}, output;
        input.key = key; input.command = SMCWrite; input.info.size = info.size;
        memcpy(input.bytes, bytes, size);
        rc = call(connection, &input, &output, error);
    }
    pthread_mutex_unlock(&connection->mutex);
    return rc;
}
