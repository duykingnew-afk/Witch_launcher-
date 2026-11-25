#import "MobileGLConfig.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

NSString *const MobileGLPrefSection = @"mobilegl";

@implementation MobileGLConfig

+ (BOOL)isMobileGLRendererSelected {
    NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    return [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL];
}

+ (MobileGLBackendType)selectedBackendType {
    id backendType = getPrefObject(@"mobilegl.backend_type");
    if (backendType && [backendType isKindOfClass:[NSString class]]) {
        NSString *bt = (NSString *)backendType;
        if ([bt isEqualToString:@"DirectGLES"]) {
            return MobileGLBackendTypeDirectGLES;
        }
    }
    return MobileGLBackendTypeDirectVulkan;
}

+ (MobileGLAngleBackend)selectedAngleBackend {
    id angleBackend = getPrefObject(@"mobilegl.angle_backend");
    if (angleBackend && [angleBackend isKindOfClass:[NSString class]]) {
        NSString *ab = (NSString *)angleBackend;
        if ([ab isEqualToString:@"vulkan"]) {
            return MobileGLAngleBackendVulkan;
        }
    }
    // Default is TGLES. The legacy value "metal" (MetalANGLE, removed) also
    // maps here so existing installs keep working after the migration.
    return MobileGLAngleBackendTGLES;
}

// Devices with 3 GB of RAM or less (iPhone 7 Plus, 8 Plus, X) reach the
// per-process Jetsam ceiling (about 2 GB) with a modded game loaded, and one
// MobileGL allocation spike is enough to close the app. On those devices the
// knobs that multiply memory are clamped whatever the saved preference says.
static const unsigned long long kLowMemoryDeviceBytes = 4ULL * 1024 * 1024 * 1024;

+ (BOOL)isLowMemoryDevice {
    return NSProcessInfo.processInfo.physicalMemory < kLowMemoryDeviceBytes;
}

+ (int)effectiveFramesInFlight {
    id framesInFlight = getPrefObject(@"mobilegl.frames_in_flight");
    int value = framesInFlight ? (int)[framesInFlight integerValue]
        : (NSProcessInfo.processInfo.physicalMemory >= (6ULL * 1024 * 1024 * 1024) ? 3 : 2);
    // Every frame-in-flight keeps its own arena slot/high-water mark. An
    // unclamped value from an old config could multiply the MobileGL arena
    // and push a 4 GB device straight into Jetsam.
    if (value < 1) value = 1;
    if (value > 4) value = 4;
    if ([self isLowMemoryDevice] && value > 2) value = 2;
    return value;
}

+ (int)effectiveVmaBlockSizeMB {
    id vmaBlockSize = getPrefObject(@"mobilegl.vma_block_size");
    int value = vmaBlockSize ? (int)[vmaBlockSize integerValue] : 32;
    if (value < 8) value = 8;
    if (value > 64) value = 64;
    // VMA blocks are allocated whole, so on a small device a 32 MB block with
    // only a few MB in use is mostly wasted memory.
    if ([self isLowMemoryDevice] && value > 16) value = 16;
    return value;
}

+ (void)applyEnvironmentFromPreferences {
    // Backend type (DirectVulkan or DirectGLES)
    MobileGLBackendType backendType = [self selectedBackendType];
    switch (backendType) {
        case MobileGLBackendTypeDirectGLES:
            setenv("MOBILEGL_BACKEND_TYPE", "DirectGLES", 1);
            break;
        default:
            setenv("MOBILEGL_BACKEND_TYPE", "DirectVulkan", 1);
            break;
    }

    // ANGLE backend (only relevant when DirectGLES is selected)
    MobileGLAngleBackend angleBackend = [self selectedAngleBackend];
    switch (angleBackend) {
        case MobileGLAngleBackendVulkan:
            setenv("MOBILEGL_ANGLE_BACKEND", "vulkan", 1);
            break;
        default:
            setenv("MOBILEGL_ANGLE_BACKEND", "tgles", 1);
            break;
    }

    id disableTimerQuery = getPrefObject(@"mobilegl.disable_timer_query");
    setenv("MOBILEGL_DISABLE_TIMERQUERY", [disableTimerQuery boolValue] ? "1" : "0", 1);

    id disableSubgroup = getPrefObject(@"mobilegl.disable_subgroup");
    setenv("MOBILEGL_MAGMA_DISABLE_SUBGROUP", [disableSubgroup boolValue] ? "1" : "0", 1);

    id advertiseFP64 = getPrefObject(@"mobilegl.advertise_fp64");
    setenv("MOBILEGL_ADVERTISE_FP64", [advertiseFP64 boolValue] ? "1" : "0", 1);

    int framesValue = [self effectiveFramesInFlight];
    char framesStr[16];
    snprintf(framesStr, sizeof(framesStr), "%d", framesValue);
    setenv("MOBILEGL_MAGMA_FRAMESINFLIGHT", framesStr, 1);

    int vmaValue = [self effectiveVmaBlockSizeMB];
    char vmaStr[16];
    snprintf(vmaStr, sizeof(vmaStr), "%d", vmaValue);
    setenv("MOBILEGL_MAGMA_VMA_BLOCK_SIZE_MB", vmaStr, 1);

    id largeBufferAdopt = getPrefObject(@"mobilegl.large_buffer_adopt_size");
    int adoptValue = largeBufferAdopt ? (int)[largeBufferAdopt integerValue] : 4;
    if (adoptValue < 1) adoptValue = 1;
    if (adoptValue > 16) adoptValue = 16;
    char adoptStr[16];
    snprintf(adoptStr, sizeof(adoptStr), "%d", adoptValue);
    setenv("MOBILEGL_LARGE_BUFFER_ADOPT_MB", adoptStr, 1);
    if ([self isLowMemoryDevice]) {
        // Automatic adoption moves large buffers into an arena that grows in
        // steps. In both Jetsam logs it went 8 -> 256 MB just before the kill,
        // so on these devices large buffers stay ordinary allocations.
        setenv("MOBILEGL_DISABLE_LARGE_BUFFER_ADOPTION", "1", 1);
    }

    id coherentAsFlush = getPrefObject(@"mobilegl.coherent_as_flush");
    setenv("MOBILEGL_COHERENT_AS_FLUSH", [coherentAsFlush boolValue] ? "1" : "0", 1);

    id asyncShader = getPrefObject(@"mobilegl.async_shader_compile");
    switch (asyncShader ? [asyncShader integerValue] : MobileGLAsyncShaderCompileAuto) {
        case MobileGLAsyncShaderCompileOn:
            setenv("MOBILEGL_ASYNC_SHADER_COMPILE", "On", 1);
            break;
        case MobileGLAsyncShaderCompileOff:
            setenv("MOBILEGL_ASYNC_SHADER_COMPILE", "Off", 1);
            break;
        default:
            setenv("MOBILEGL_ASYNC_SHADER_COMPILE", "Auto", 1);
            break;
    }

    id shaderCache = getPrefObject(@"mobilegl.shader_cache");
    switch (shaderCache ? [shaderCache integerValue] : MobileGLShaderCacheAuto) {
        case MobileGLShaderCacheOn:
            setenv("MOBILEGL_SHADER_CACHE", "On", 1);
            break;
        case MobileGLShaderCacheOff:
            setenv("MOBILEGL_SHADER_CACHE", "Off", 1);
            break;
        default:
            setenv("MOBILEGL_SHADER_CACHE", "Auto", 1);
            break;
    }

    id r11g11b10f = getPrefObject(@"mobilegl.r11g11b10f_fallback");
    setenv("MOBILEGL_MAGMA_R11G11B10F_FALLBACK", [r11g11b10f boolValue] ? "1" : "0", 1);

    NSLog(@"[MobileGLConfig] Applied config: backend=%s angle=%s timerQ=%s subgroup=%s fp64=%s frames=%s vmaBlock=%sMB adoptThreshold=%sMB coherent=%s async=%s cache=%s r11g11b10f=%s device=%s adoption=%s",
        getenv("MOBILEGL_BACKEND_TYPE"),
        getenv("MOBILEGL_ANGLE_BACKEND"),
        getenv("MOBILEGL_DISABLE_TIMERQUERY"),
        getenv("MOBILEGL_MAGMA_DISABLE_SUBGROUP"),
        getenv("MOBILEGL_ADVERTISE_FP64"),
        getenv("MOBILEGL_MAGMA_FRAMESINFLIGHT"),
        getenv("MOBILEGL_MAGMA_VMA_BLOCK_SIZE_MB"),
        getenv("MOBILEGL_LARGE_BUFFER_ADOPT_MB"),
        getenv("MOBILEGL_COHERENT_AS_FLUSH"),
        getenv("MOBILEGL_ASYNC_SHADER_COMPILE"),
        getenv("MOBILEGL_SHADER_CACHE"),
        getenv("MOBILEGL_MAGMA_R11G11B10F_FALLBACK"),
        [self isLowMemoryDevice] ? "low-RAM" : "normal",
        getenv("MOBILEGL_DISABLE_LARGE_BUFFER_ADOPTION") ? "off" : "auto");
}

+ (NSString *)activeConfigSummary {
    NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];

    MobileGLBackendType backendType = [self selectedBackendType];
    NSString *backend = (backendType == MobileGLBackendTypeDirectGLES) ? @"DirectGLES" : @"DirectVulkan";

    MobileGLAngleBackend angleBackend = [self selectedAngleBackend];
    NSString *angleStr = (angleBackend == MobileGLAngleBackendVulkan) ? @"VulkanANGLE" : @"TGLES";

    id disableTimerQuery = getPrefObject(@"mobilegl.disable_timer_query");
    NSString *timerQ = disableTimerQuery ? ([disableTimerQuery boolValue] ? @"YES" : @"NO") : @"NO";

    id disableSubgroup = getPrefObject(@"mobilegl.disable_subgroup");
    NSString *subgroup = disableSubgroup ? ([disableSubgroup boolValue] ? @"YES" : @"NO") : @"NO";

    id advertiseFP64 = getPrefObject(@"mobilegl.advertise_fp64");
    NSString *fp64 = advertiseFP64 ? ([advertiseFP64 boolValue] ? @"YES" : @"NO") : @"NO";

    // Effective values after the clamps; the saved value is shown when they differ.
    id framesInFlight = getPrefObject(@"mobilegl.frames_in_flight");
    int framesEffective = [self effectiveFramesInFlight];
    NSString *frames = (framesInFlight && [framesInFlight integerValue] != framesEffective)
        ? [NSString stringWithFormat:@"%d (saved %ld)", framesEffective, (long)[framesInFlight integerValue]]
        : [NSString stringWithFormat:@"%d", framesEffective];

    id vmaBlockSize = getPrefObject(@"mobilegl.vma_block_size");
    int vmaEffective = [self effectiveVmaBlockSizeMB];
    NSString *vmaBlock = (vmaBlockSize && [vmaBlockSize integerValue] != vmaEffective)
        ? [NSString stringWithFormat:@"%dMB (saved %ldMB)", vmaEffective, (long)[vmaBlockSize integerValue]]
        : [NSString stringWithFormat:@"%dMB", vmaEffective];

    id largeBufferAdopt = getPrefObject(@"mobilegl.large_buffer_adopt_size");
    NSString *adoptThreshold = [self isLowMemoryDevice]
        ? @"off (low-RAM device)"
        : (largeBufferAdopt ? [NSString stringWithFormat:@"%ldMB", (long)[largeBufferAdopt integerValue]] : @"4MB");

    id coherentAsFlush = getPrefObject(@"mobilegl.coherent_as_flush");
    NSString *coherent = coherentAsFlush ? ([coherentAsFlush boolValue] ? @"YES" : @"NO") : @"NO";

    id asyncShader = getPrefObject(@"mobilegl.async_shader_compile");
    NSString *asyncStr;
    switch (asyncShader ? [asyncShader integerValue] : MobileGLAsyncShaderCompileAuto) {
        case MobileGLAsyncShaderCompileOn: asyncStr = @"On"; break;
        case MobileGLAsyncShaderCompileOff: asyncStr = @"Off"; break;
        default: asyncStr = @"Auto"; break;
    }

    id shaderCache = getPrefObject(@"mobilegl.shader_cache");
    NSString *cacheStr;
    switch (shaderCache ? [shaderCache integerValue] : MobileGLShaderCacheAuto) {
        case MobileGLShaderCacheOn: cacheStr = @"On"; break;
        case MobileGLShaderCacheOff: cacheStr = @"Off"; break;
        default: cacheStr = @"Auto"; break;
    }

    id r11g11b10f = getPrefObject(@"mobilegl.r11g11b10f_fallback");
    NSString *r11 = r11g11b10f ? ([r11g11b10f boolValue] ? @"YES" : @"NO") : @"NO";

    return [NSString stringWithFormat:
        @"[MobileGL Config]\n"
        @"Renderer: %@\n"
        @"Backend: %@\n"
        @"ANGLE Backend: %@\n"
        @"Timer Query: %@ / Subgroup: %@\n"
        @"FP64: %@ / Frames in Flight: %@\n"
        @"VMA Block: %@ / Buffer Adopt Threshold: %@\n"
        @"Coherent: %@ / Async: %@ / Cache: %@\n"
        @"R11G11B10F: %@",
        renderer, backend, angleStr,
        timerQ, subgroup,
        fp64, frames,
        vmaBlock, adoptThreshold,
        coherent, asyncStr, cacheStr,
        r11];
}

@end
