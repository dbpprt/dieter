#import "VirtualDisplayBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <string.h>

@interface NSObject (DieterVirtualDisplayAPI)
- (instancetype)initWithDescriptor:(id)descriptor;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refresh;
- (BOOL)applySettings:(id)settings;
@end

double DieterDisplayBackingScale(unsigned int displayID) {
    void (*currentMode)(CGDirectDisplayID, int *) = dlsym(RTLD_DEFAULT, "CGSGetCurrentDisplayMode");
    void (*countModes)(CGDirectDisplayID, int *) = dlsym(RTLD_DEFAULT, "CGSGetNumberOfDisplayModes");
    void (*describeMode)(CGDirectDisplayID, int, void *, int) = dlsym(RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
    if (!currentMode || !countModes || !describeMode) return 1;
    int current = -1, count = 0;
    currentMode(displayID, &current);
    countModes(displayID, &count);
    if (count <= 0 || count > 256 || current < 0) return 1;
    for (int index = 0; index < count; index++) {
        uint8_t description[0xDC] = {0};
        describeMode(displayID, index, description, 0xD4);
        uint32_t mode;
        float density;
        memcpy(&mode, description, 4);
        memcpy(&density, description + 0xD0, 4);
        if (mode == (uint32_t)current && (density == 1 || density == 2)) return density;
    }
    return 1;
}

BOOL DieterSelectVirtualDisplayMode(unsigned int displayID, unsigned int width, unsigned int height, unsigned int scale) {
    // The public mode catalog can be empty for CGVirtualDisplay. Resolve the
    // WindowServer catalog at runtime, with a bounded ABI buffer and count.
    void (*countModes)(CGDirectDisplayID, int *) = dlsym(RTLD_DEFAULT, "CGSGetNumberOfDisplayModes");
    void (*describeMode)(CGDirectDisplayID, int, void *, int) = dlsym(RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
    void (*configureMode)(CGDisplayConfigRef, CGDirectDisplayID, int) = dlsym(RTLD_DEFAULT, "CGSConfigureDisplayMode");
    if (!countModes || !describeMode || !configureMode || (scale != 1 && scale != 2)) return NO;
    int count = 0;
    countModes(displayID, &count);
    if (count <= 0 || count > 256) return NO;
    for (int index = 0; index < count; index++) {
        uint8_t description[0xDC] = {0};
        describeMode(displayID, index, description, 0xD4);
        uint32_t mode, logicalWidth, logicalHeight;
        float density;
        memcpy(&mode, description, 4);
        memcpy(&logicalWidth, description + 8, 4);
        memcpy(&logicalHeight, description + 12, 4);
        memcpy(&density, description + 0xD0, 4);
        if (logicalWidth != width / scale || logicalHeight != height / scale || density != (float)scale) continue;
        CGDisplayConfigRef configuration;
        if (CGBeginDisplayConfiguration(&configuration) != kCGErrorSuccess) return NO;
        configureMode(configuration, displayID, mode);
        return CGCompleteDisplayConfiguration(configuration, kCGConfigureForAppOnly) == kCGErrorSuccess;
    }
    return NO;
}

NSObject *DieterCreateVirtualDisplay(unsigned int width, unsigned int height, unsigned int scale) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) return nil;
    @try {
        NSObject *descriptor = [[descriptorClass alloc] init];
        [descriptor setValue:@"Dieter Virtual Display" forKey:@"name"];
        [descriptor setValue:@(width) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(height) forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(width * 0.2646, height * 0.2646)] forKey:@"sizeInMillimeters"];
        [descriptor setValue:@(0x4449) forKey:@"vendorID"];
        [descriptor setValue:@0 forKey:@"productID"];
        NSNumber *serial = @(arc4random_uniform(UINT32_MAX - 1) + 1);
        [descriptor setValue:serial forKey:@"serialNum"];
        if ([descriptor respondsToSelector:NSSelectorFromString(@"setSerialNumber:")]) {
            [descriptor setValue:serial forKey:@"serialNumber"];
        }
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3125, 0.3291)] forKey:@"whitePoint"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.6797, 0.3203)] forKey:@"redPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.2559, 0.6983)] forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.1494, 0.0557)] forKey:@"bluePrimary"];
        [descriptor setValue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0) forKey:@"queue"];
        NSObject *display = [[displayClass alloc] initWithDescriptor:descriptor];
        NSObject *mode = [[modeClass alloc] initWithWidth:width / scale height:height / scale refreshRate:60.0];
        if (!display || !mode) return nil;
        NSObject *settings = [[settingsClass alloc] init];
        [settings setValue:@(scale == 2) forKey:@"hiDPI"];
        [settings setValue:@0 forKey:@"rotation"];
        [settings setValue:@[mode] forKey:@"modes"];
        if (![display applySettings:settings]) return nil;
        return display;
    } @catch (NSException *exception) {
        // Private API drift is an unsupported capability, never a daemon crash.
        return nil;
    }
}
