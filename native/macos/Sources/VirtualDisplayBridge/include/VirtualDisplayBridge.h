#import <Foundation/Foundation.h>

// The bridge uses Objective-C initializer ownership rules for private objects.
// Swift never invokes an initializer on an already initialized virtual display.
FOUNDATION_EXPORT NSObject * _Nullable DieterCreateVirtualDisplay(unsigned int width, unsigned int height, unsigned int scale) NS_RETURNS_RETAINED;
FOUNDATION_EXPORT BOOL DieterSelectVirtualDisplayMode(unsigned int displayID, unsigned int width, unsigned int height, unsigned int scale);
FOUNDATION_EXPORT double DieterDisplayBackingScale(unsigned int displayID);
