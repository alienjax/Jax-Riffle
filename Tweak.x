// Jax Riffle
// Swipe the dock sideways, like inside a folder, to reveal more pages of apps.
// Rootless (Dopamine) · iOS 15.0–16.x · iPhone
//
// How it works
//  1. SpringBoard's dock layout (SBIconLocationDock) and dock capacity are raised to 4 slots per page, so
//     SpringBoard itself stores, saves and handles drag and drop for the extra apps, as one long row of slots.
//  2. Positions come from SpringBoard: at the dock's normal size, its own dock layout method
//     (-[SBDockIconListView originForIconAtCoordinate:numberOfIcons:] on iOS 16) is asked where it puts
//     each app when the dock holds 4, 3, 2 or 1 apps. Every page then puts its apps on exactly those spots.
//     If that can't be measured, the apps are spaced evenly across the dock background instead.
//  3. The dock's icon list is moved into a paging scroll view, one page wide, clipped to the dock background.
//  4. Every hook goes through Substrate (ElleKit on Dopamine) and nothing catches exceptions, so if anything
//     ever goes wrong SpringBoard crashes into Safe Mode as usual.
//  5. What was measured and decided is written to a diagnostics report (Settings → Jax Riffle →
//     Copy Diagnostics).
//  6. It can never freeze SpringBoard: nothing asks for a new layout from inside a layout pass, a layout
//     that keeps repeating switches the tweak off on the spot, and a watchdog thread notices a frozen
//     main thread, switches the tweak off and restarts SpringBoard long before the system's 3-minute
//     watchdog would. After that the tweak stays off until it is turned back on in Settings.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#define JRFVersion @"0.3.7"
#define JRFPrefsDomain @"com.alienjax.riffle"
#define JRFPrefsChangedNotification "com.alienjax.riffle/ReloadPrefs"
#define JRFDockBackupPath @"/var/mobile/Library/Preferences/com.alienjax.riffle.dock-backup.plist"
#define JRFDiagnosticsPath @"/var/mobile/Library/Preferences/com.alienjax.riffle.diagnostics.txt"
#define JRFSafetyPath @"/var/mobile/Library/Preferences/com.alienjax.riffle.safety.plist"
#define JRFLog(fmt, ...) NSLog(@"[JaxRiffle] " fmt, ##__VA_ARGS__)

// Freeze protection thresholds.
#define JRFMaxDockLayoutsPerSecond 300   // a layout loop runs thousands per second; animations need ~60
#define JRFMaxIconLayoutsPerSecond 600
#define JRFMaxTakeoversPer10Seconds 12
#define JRFFreezeSwitchOffSeconds 10.0   // main thread stuck this long: switch off, record where it was stuck
#define JRFFreezeRestartSeconds 30.0     // still stuck: restart SpringBoard (the system waits 180 s, then panics)
#define JRFLaunchFreezeSwitchOffSeconds 20.0 // the same before the main run loop has started (launch is slower)
#define JRFLaunchFreezeRestartSeconds 40.0

#define JRFAppsPerPage 4 // most apps on one page, like the stock iPhone dock
#define JRFMaxPages 10    // pages appear as they're needed, up to this many (40 apps)

static NSString *const JRFDockIconLocation = @"SBIconLocationDock";
static NSString *const JRFIconStateDockKey = @"buttonBar";
static NSString *const JRFIconStateListsKey = @"iconLists";

#pragma mark - SpringBoard interfaces (SpringBoardHome, iOS 15/16)

typedef struct JRFGridSize { // SBHIconGridSize
	uint16_t columns;
	uint16_t rows;
} JRFGridSize;

typedef struct JRFIconImageInfo { // SBIconImageInfo
	CGSize size;
	CGFloat scale;
	CGFloat continuousCornerRadius;
} JRFIconImageInfo;

// SBIconCoordinate: a row and a column, both counted from 1. iOS 16 swapped the two fields, so the tweak
// never relies on their order: in a one-row dock one field is always the first row, so the larger
// value is the slot.
typedef struct JRFIconCoordinate {
	NSInteger first;
	NSInteger second;
} JRFIconCoordinate;

@interface SBIconListGridLayoutConfiguration : NSObject
@property (nonatomic, assign) NSUInteger numberOfPortraitColumns;
@property (nonatomic, assign) NSUInteger numberOfPortraitRows;
@property (nonatomic, assign) NSUInteger numberOfLandscapeColumns;
@property (nonatomic, assign) NSUInteger numberOfLandscapeRows;
@end

@interface SBIconListFlowLayout : NSObject
- (SBIconListGridLayoutConfiguration *)layoutConfiguration;
@end

@interface SBHDefaultIconListLayoutProvider : NSObject
- (id)layoutForIconLocation:(NSString *)iconLocation;
@end

@interface SBIcon : NSObject
- (NSUInteger)gridSizeClass;
- (BOOL)isFolderIcon;
@end

@interface SBIconListModel : NSObject
- (NSArray *)icons;
- (NSUInteger)numberOfIcons;
- (id)folder;
- (JRFGridSize)gridSize;
- (NSUInteger)maxNumberOfIcons;
- (BOOL)isFull;
@end

@interface SBFolder : NSObject
- (NSArray *)lists;
- (SBIconListModel *)dock;
@end

@interface SBIconListViewLayoutMetrics : NSObject
- (UIEdgeInsets)iconInsets;
- (CGSize)alignmentIconSize;
- (CGSize)iconSpacing;
@end

@interface SBIconListView : UIView
- (NSInteger)layoutOrientation;
- (NSInteger)orientation;
- (SBIconListModel *)model;
- (id)layout;
- (id)layoutMetrics;
- (id)layoutMetricsForOrientation:(NSInteger)orientation;
- (CGSize)iconSpacing;
- (CGSize)effectiveIconSpacing;
- (CGSize)defaultIconSize;
- (BOOL)automaticallyAdjustsLayoutMetricsToFit;
- (BOOL)isEditing;
- (void)setEditing:(BOOL)editing;
- (void)layoutIconsNow;
- (NSRange)visibleColumnRange;
- (void)setVisibleColumnRange:(NSRange)range;
- (JRFIconCoordinate)iconCoordinateForIndex:(NSUInteger)index metrics:(id)metrics;
- (JRFIconCoordinate)coordinateAtPoint:(CGPoint)point;
- (CGPoint)originForIconAtCoordinate:(JRFIconCoordinate)coordinate metrics:(id)metrics;
- (CGPoint)centerForIconCoordinate:(JRFIconCoordinate)coordinate metrics:(id)metrics;
- (NSUInteger)columnAtPoint:(CGPoint)point metrics:(id)metrics fractionOfDistanceThroughColumn:(double *)fraction;
- (NSUInteger)rowAtPoint:(CGPoint)point metrics:(id)metrics;
- (BOOL)allowsAddingIconCount:(NSUInteger)count;
@end

@interface SBDockIconListView : SBIconListView
+ (NSUInteger)maxIcons;
- (CGPoint)originForIconAtCoordinate:(JRFIconCoordinate)coordinate numberOfIcons:(NSUInteger)numberOfIcons;
@end

@interface SBIconView : UIView
- (id)icon;
@end

@interface SBDockView : UIView
- (id)dockListView;
- (UIView *)backgroundView;
@end

@interface SBHIconManager : NSObject
- (BOOL)isEditing;
- (id)rootFolderController;
@end

// The Home Screen's folder controller (SBRootFolderController).
@interface JRFFolderControllerStandIn : NSObject
- (NSArray *)iconListViews;
- (SBIconListView *)currentIconListView;
@end

@interface SBIconController : UIViewController
+ (instancetype)sharedInstance;
- (SBHIconManager *)iconManager;
- (NSUInteger)maxIconCountForDock;
@end

@interface SBDefaultIconModelStore : NSObject
- (id)loadCurrentIconState:(NSError **)error;
- (BOOL)saveCurrentIconState:(id)state error:(NSError **)error;
@end

// SpringBoard's Home button handling.
@interface SBHomeHardwareButtonActions : NSObject
@end

@interface SpringBoard : UIApplication
@end

@interface SBUIController : NSObject
@end

// SpringBoard's drop handler for an icon list (one per list).
@interface SBIconListViewDraggingDestinationDelegate : NSObject
- (SBIconListView *)iconListView;
@end

// Stand-in name for the root folder class that owns the dock (SBRootFolderWithDock on iOS 15/16).
@interface JRFRootFolderStandIn : NSObject
- (id)dock;
@end

#pragma mark - Preferences

static BOOL gEnabled = YES;            // read at launch
static NSUInteger gPages = JRFMaxPages; // most pages; they appear and disappear with the apps
static BOOL gShowDots = YES;           // live
static BOOL gFlipWhileDragging = YES;  // live
static BOOL gHomeResetsDock = YES;     // live: the Home button also takes the dock back to page 1
static BOOL gAppOpenResetsDock = NO;   // live: opening an app takes the dock back to page 1
static BOOL gRestoreDock = YES;        // live
static NSUInteger gIconsPerPage = 0;   // learned from the stock dock layout (4 on iPhone)

static BOOL JRFPrefBool(NSUserDefaults *defaults, NSString *key, BOOL fallback) {
	id value = [defaults objectForKey:key];
	return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static void JRFLoadLivePrefs(void) {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:JRFPrefsDomain];
	gShowDots = JRFPrefBool(defaults, @"showDots", YES);
	gFlipWhileDragging = JRFPrefBool(defaults, @"flipWhileDragging", YES);
	gHomeResetsDock = JRFPrefBool(defaults, @"homeResetsDock", YES);
	gAppOpenResetsDock = JRFPrefBool(defaults, @"appOpenResetsDock", NO);
	gRestoreDock = JRFPrefBool(defaults, @"restoreDock", YES);
}

static void JRFLoadLaunchPrefs(void) {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:JRFPrefsDomain];
	gEnabled = JRFPrefBool(defaults, @"enabled", YES);
}

static NSUInteger JRFIconsPerPage(void) {
	return gIconsPerPage ?: JRFAppsPerPage;
}

static NSUInteger JRFDockCapacity(void) {
	return JRFIconsPerPage() * gPages;
}

#pragma mark - Diagnostics report

// Changed on the main thread only. The lock lets the watchdog thread read them while the main thread is stuck.
static NSMutableDictionary<NSString *, NSString *> *gDiag;
static NSMutableArray<NSString *> *gDiagEvents;
static NSString *gDiagSafetyText;       // why the tweak switched itself off, with where SpringBoard was stuck
static os_unfair_lock gDiagLock = OS_UNFAIR_LOCK_INIT;
static BOOL gDiagWritePending;
static CFTimeInterval gLaunchTime;

static NSString *JRFDiagText(void) {
	os_unfair_lock_lock(&gDiagLock);
	NSDictionary *values = [gDiag copy];
	NSArray *events = [gDiagEvents copy];
	NSString *safety = gDiagSafetyText;
	os_unfair_lock_unlock(&gDiagLock);

	NSMutableString *text = [NSMutableString stringWithFormat:@"Jax Riffle %@ diagnostics, written %@\n\n", JRFVersion, [NSDate date]];
	if (safety.length) [text appendFormat:@"%@\n\n", safety];
	for (NSString *key in [[values allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
		[text appendFormat:@"%@: %@\n", key, values[key]];
	}
	[text appendString:@"\nEvents (oldest first, seconds since SpringBoard started):\n"];
	for (NSString *line in events) [text appendFormat:@"- %@\n", line];
	return text;
}

// Any thread.
static void JRFDiagWrite(void) {
	if (!gDiag) return;
	[JRFDiagText() writeToFile:JRFDiagnosticsPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void JRFDiagFlushSoon(void) {
	if (!gDiag || gDiagWritePending) return;
	gDiagWritePending = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		gDiagWritePending = NO;
		JRFDiagWrite();
	});
}

static void JRFDiagSet(NSString *key, NSString *value) {
	if (!gDiag || ![NSThread isMainThread]) return;
	NSString *text = value ?: @"(none)";
	os_unfair_lock_lock(&gDiagLock);
	BOOL same = [gDiag[key] isEqualToString:text];
	if (!same) gDiag[key] = text;
	os_unfair_lock_unlock(&gDiagLock);
	if (!same) JRFDiagFlushSoon();
}

static void JRFDiagEvent(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void JRFDiagEvent(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);
	JRFLog(@"%@", line);
	if (!gDiagEvents || ![NSThread isMainThread]) return;
	line = [NSString stringWithFormat:@"%.1f: %@", CACurrentMediaTime() - gLaunchTime, line];
	os_unfair_lock_lock(&gDiagLock);
	[gDiagEvents addObject:line];
	while (gDiagEvents.count > 80) [gDiagEvents removeObjectAtIndex:0];
	os_unfair_lock_unlock(&gDiagLock);
	JRFDiagFlushSoon();
}

static NSString *JRFYesNo(BOOL value) {
	return value ? @"yes" : @"no";
}

#pragma mark - Safety switch

// Set (from any thread) when something goes wrong. From then on every hook stands aside and SpringBoard
// works exactly as if the tweak weren't there.
static atomic_bool gTripped;

static inline BOOL JRFActive(void) {
	return !atomic_load_explicit(&gTripped, memory_order_relaxed);
}

typedef struct JRFRate {
	CFTimeInterval start;
	NSUInteger count;
} JRFRate;

// Main thread. YES once more than `limit` calls happen within `window` seconds.
static BOOL JRFRateExceeded(JRFRate *rate, NSUInteger limit, CFTimeInterval window) {
	CFTimeInterval now = CACurrentMediaTime();
	if (now - rate->start >= window) {
		rate->start = now;
		rate->count = 0;
	}
	return ++rate->count > limit;
}

// The safety record: while it exists (for this version), the tweak doesn't load. Settings shows it and can
// remove it ("Turn Back On").
static NSDictionary *JRFReadSafetyRecord(void) {
	NSData *data = [NSData dataWithContentsOfFile:JRFSafetyPath];
	if (!data) return nil;
	id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
	return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
}

static void JRFWriteSafetyRecord(NSString *reason, NSString *details) {
	NSDictionary *record = @{
		@"tripped": @YES,
		@"reason": reason ?: @"",
		@"details": details ?: @"",
		@"version": JRFVersion,
		@"date": [NSDate date],
	};
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
	[data writeToFile:JRFSafetyPath atomically:YES];
}

static void JRFRestoreStockDocks(void);

// Switches the tweak off right away (any thread): hooks stand aside immediately, the dock is handed back
// to SpringBoard on the main thread, and the tweak stays off on later launches until turned back on.
static void JRFTrip(NSString *reason, NSString *details) {
	BOOL first = !atomic_exchange(&gTripped, true);
	JRFWriteSafetyRecord(reason, details); // the latest problem is the one reported
	os_unfair_lock_lock(&gDiagLock);
	gDiagSafetyText = [NSString stringWithFormat:@"SWITCHED ITSELF OFF: %@\n%@", reason, details.length ? details : @""];
	os_unfair_lock_unlock(&gDiagLock);
	JRFLog(@"Switched itself off: %@", reason);
	JRFDiagWrite(); // now, in case the main thread is stuck
	if (!first) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		JRFDiagEvent(@"Switched itself off: %@", reason);
		JRFRestoreStockDocks();
		JRFDiagWrite();
	});
}

#pragma mark - Runtime helpers

static Class gDockListViewClass;
static Class gIconViewClass;
static Class gMetricsClass;

static Ivar JRFFindIvar(id object, const char *name) {
	return object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
}

static id JRFObjectIvar(id object, const char *name) {
	Ivar ivar = JRFFindIvar(object, name);
	const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
	if (!type || type[0] != '@') return nil;
	return object_getIvar(object, ivar);
}

// Pointer to an ivar, only if its type encoding starts with `typePrefix` (so the wrong type is never written).
static void *JRFIvarPointer(id object, const char *name, const char *typePrefix) {
	Ivar ivar = JRFFindIvar(object, name);
	const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
	if (!type || strncmp(type, typePrefix, strlen(typePrefix)) != 0) return NULL;
	return (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
}

static BOOL JRFBoolIvar(id object, const char *name, BOOL fallback) {
	BOOL *pointer = JRFIvarPointer(object, name, "B");
	return pointer ? *pointer : fallback;
}

static BOOL JRFIsDockListView(id view) {
	return gDockListViewClass && [view isKindOfClass:gDockListViewClass];
}

static BOOL JRFRectsClose(CGRect a, CGRect b) {
	if (CGRectIsNull(a) || CGRectIsNull(b)) return NO;
	return fabs(a.origin.x - b.origin.x) < 0.01 && fabs(a.origin.y - b.origin.y) < 0.01 &&
	       fabs(a.size.width - b.size.width) < 0.01 && fabs(a.size.height - b.size.height) < 0.01;
}

// Rect from main-axis (along the dock) and cross-axis values.
static CGRect JRFRectAlong(BOOL horizontal, CGFloat mainOrigin, CGFloat mainLength, CGFloat crossOrigin, CGFloat crossLength) {
	return horizontal ? CGRectMake(mainOrigin, crossOrigin, mainLength, crossLength)
	                  : CGRectMake(crossOrigin, mainOrigin, crossLength, mainLength);
}

static CGFloat JRFMainOf(CGPoint point, BOOL horizontal) {
	return horizontal ? point.x : point.y;
}

static CGFloat JRFCrossOf(CGPoint point, BOOL horizontal) {
	return horizontal ? point.y : point.x;
}

static CGFloat JRFMainLength(CGSize size, BOOL horizontal) {
	return horizontal ? size.width : size.height;
}

static CGFloat JRFCrossLength(CGSize size, BOOL horizontal) {
	return horizontal ? size.height : size.width;
}

static CGPoint JRFPointAlong(BOOL horizontal, CGFloat main, CGFloat cross) {
	return horizontal ? CGPointMake(main, cross) : CGPointMake(cross, main);
}

static CGPoint JRFShiftAlong(CGPoint point, BOOL horizontal, CGFloat delta) {
	if (horizontal) point.x += delta;
	else point.y += delta;
	return point;
}

static CGFloat JRFScreenScale(UIView *view) {
	CGFloat scale = view.window.screen.scale;
	if (!(scale > 0)) scale = UIScreen.mainScreen.scale;
	return scale > 0 ? scale : 2.0;
}

static CGFloat JRFRoundToPixel(CGFloat value, CGFloat scale) {
	return round(value * scale) / scale;
}

static NSInteger JRFListOrientation(SBIconListView *list) {
	if ([list respondsToSelector:@selector(layoutOrientation)]) return [list layoutOrientation];
	if ([list respondsToSelector:@selector(orientation)]) return [list orientation];
	return UIInterfaceOrientationPortrait;
}

static NSUInteger JRFIconCount(SBIconListView *list) {
	return [[[list model] icons] count];
}

static NSArray<UIView *> *JRFIconViews(SBIconListView *list) {
	NSMutableArray *views = [NSMutableArray array];
	if (!gIconViewClass) return views;
	for (UIView *view in list.subviews) {
		if ([view isKindOfClass:gIconViewClass] && [view respondsToSelector:@selector(icon)]) [views addObject:view];
	}
	return views;
}

// Size of a dock app's icon view, for when SpringBoard's own metrics aren't available.
static CGSize JRFIconViewSize(SBIconListView *list) {
	for (UIView *view in JRFIconViews(list)) {
		CGSize size = view.bounds.size;
		if (size.width > 1 && size.height > 1) return size;
	}
	if ([list respondsToSelector:@selector(defaultIconSize)]) {
		CGSize size = [list defaultIconSize];
		if (size.width > 1 && size.height > 1 && isfinite(size.width) && isfinite(size.height)) return size;
	}
	return CGSizeMake(60, 60);
}

#pragma mark - Dock model and capacity

static __weak SBIconListModel *gDockModel;

// Raises the dock model's stored capacity (Atria does the same on iOS 14–16), so checks that read the
// stored value rather than calling a method still see room for every page.
static void JRFRaiseDockModelStorage(SBIconListModel *model) {
	NSUInteger capacity = JRFDockCapacity();
	Ivar gridIvar = JRFFindIvar(model, "_gridSize");
	const char *gridType = gridIvar ? ivar_getTypeEncoding(gridIvar) : NULL;
	if (gridType && gridType[0] == '{' && strstr(gridType, "=SS}")) {
		JRFGridSize *grid = (JRFGridSize *)((uint8_t *)(__bridge void *)model + ivar_getOffset(gridIvar));
		if ((NSUInteger)grid->columns * grid->rows < capacity) {
			if (grid->rows <= 1) {
				grid->columns = (uint16_t)capacity;
				grid->rows = 1;
			} else if (grid->columns <= 1) {
				grid->rows = (uint16_t)capacity;
			}
		}
	}
	unsigned long long *maxCount = JRFIvarPointer(model, "_maxNumberOfIcons", "Q");
	if (maxCount && *maxCount > 0 && *maxCount < capacity) *maxCount = capacity;
}

static void JRFNoteDockModel(SBIconListModel *model) {
	if (!model || gDockModel == model) return;
	gDockModel = model;
	JRFRaiseDockModelStorage(model);
	if ([NSThread isMainThread]) JRFDiagEvent(@"Found the dock's app list (%@)", NSStringFromClass([model class]));
}

static BOOL JRFIsDockModel(id model) {
	if (!model) return NO;
	SBIconListModel *dock = gDockModel;
	if (dock) return dock == model;
	if (![model respondsToSelector:@selector(folder)]) return NO;
	id folder = [model folder];
	if (![folder respondsToSelector:@selector(dock)]) return NO;
	return [folder dock] == model; // the -dock hook records it for next time
}

#pragma mark - Dock layout configuration

@interface JRFStockGrid : NSObject
@property (nonatomic) NSUInteger portraitColumns;
@property (nonatomic) NSUInteger portraitRows;
@property (nonatomic) NSUInteger landscapeColumns;
@property (nonatomic) NSUInteger landscapeRows;
@end

@implementation JRFStockGrid
@end

static const void *JRFStockGridKey = &JRFStockGridKey;
static NSHashTable *gPatchedConfigs; // dock layout configurations whose grid the tweak raised (to put back)

// > 0 (on the main thread) while asking SpringBoard how a stock dock is laid out. The dock's layout
// configuration and list model then report their stock sizes, and the tweak's own overrides stand aside.
static NSInteger gStockQueryDepth = 0;
static JRFGridSize gStockDockModelGrid = { 0, 0 };

static BOOL JRFStockQueryActive(void) {
	return gStockQueryDepth > 0 && [NSThread isMainThread];
}

// Makes the long side of the dock grid hold every page: 4 slots per page. Idempotent: the stock values are
// remembered on the configuration object the first time it is seen.
static BOOL JRFPatchDockConfiguration(SBIconListGridLayoutConfiguration *config) {
	if (!JRFActive() || ![config respondsToSelector:@selector(setNumberOfPortraitColumns:)]) return NO;

	JRFStockGrid *stock = objc_getAssociatedObject(config, JRFStockGridKey);
	if (!stock) {
		stock = [JRFStockGrid new];
		stock.portraitColumns = config.numberOfPortraitColumns;
		stock.portraitRows = config.numberOfPortraitRows;
		stock.landscapeColumns = config.numberOfLandscapeColumns;
		stock.landscapeRows = config.numberOfLandscapeRows;
		objc_setAssociatedObject(config, JRFStockGridKey, stock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		NSString *grid = [NSString stringWithFormat:@"%lu x %lu portrait, %lu x %lu landscape",
			(unsigned long)stock.portraitColumns, (unsigned long)stock.portraitRows,
			(unsigned long)stock.landscapeColumns, (unsigned long)stock.landscapeRows];
		JRFDiagSet(@"stock dock grid", grid);
		JRFLog(@"Stock dock grid: %@", grid);
	}

	// Only a normal one-row dock (another tweak may have changed it).
	NSUInteger stockLong = MAX(stock.portraitColumns, stock.portraitRows);
	if (MIN(stock.portraitColumns, stock.portraitRows) != 1 || stockLong < 2 || stockLong > 8) return NO;
	NSUInteger perPage = MIN(stockLong, (NSUInteger)JRFAppsPerPage);
	if (!gIconsPerPage) gIconsPerPage = perPage;
	NSUInteger slots = perPage * gPages;

	NSUInteger portraitColumns = stock.portraitColumns, portraitRows = stock.portraitRows;
	if (portraitColumns >= portraitRows) portraitColumns = slots; else portraitRows = slots;
	NSUInteger landscapeColumns = stock.landscapeColumns, landscapeRows = stock.landscapeRows;
	if (MIN(landscapeColumns, landscapeRows) == 1 && MAX(landscapeColumns, landscapeRows) >= 2) {
		if (landscapeColumns >= landscapeRows) landscapeColumns = slots; else landscapeRows = slots;
	}

	if ([NSThread isMainThread]) [gPatchedConfigs addObject:config];
	BOOL changed = NO;
	if (config.numberOfPortraitColumns != portraitColumns) { config.numberOfPortraitColumns = portraitColumns; changed = YES; }
	if (config.numberOfPortraitRows != portraitRows) { config.numberOfPortraitRows = portraitRows; changed = YES; }
	if (config.numberOfLandscapeColumns != landscapeColumns) { config.numberOfLandscapeColumns = landscapeColumns; changed = YES; }
	if (config.numberOfLandscapeRows != landscapeRows) { config.numberOfLandscapeRows = landscapeRows; changed = YES; }
	return changed;
}

static SBIconListGridLayoutConfiguration *JRFLayoutConfigurationForList(SBIconListView *list) {
	id layout = [list respondsToSelector:@selector(layout)] ? [list layout] : nil;
	return [layout respondsToSelector:@selector(layoutConfiguration)] ? [layout layoutConfiguration] : nil;
}

#pragma mark - Icon coordinates

static NSInteger gSlotBase = 1;              // SBIconCoordinate value of the first row / column
static BOOL gColumnIsFirstField = NO;        // set from the iOS version, then confirmed at runtime
static BOOL gFieldOrderKnown = NO;
static NSInteger gColumnAtPointBase = 0;     // what -columnAtPoint:… returns for the first slot
static NSInteger gRowAtPointBase = 0;        // what -rowAtPoint:… returns for the first slot
static BOOL gColumnAtPointBaseKnown = NO;
static BOOL gRowAtPointBaseKnown = NO;

// The slot index of a coordinate in the one-row dock, whichever field holds the column.
static NSInteger JRFIndexForCoordinate(JRFIconCoordinate coordinate) {
	return MAX(coordinate.first, coordinate.second) - gSlotBase;
}

static JRFIconCoordinate JRFMakeCoordinate(NSUInteger index, BOOL horizontal) {
	JRFIconCoordinate coordinate = { gSlotBase, gSlotBase };
	BOOL firstRunsAlong = horizontal ? gColumnIsFirstField : !gColumnIsFirstField;
	if (firstRunsAlong) coordinate.first += (NSInteger)index;
	else coordinate.second += (NSInteger)index;
	return coordinate;
}

static JRFIconCoordinate JRFCoordinateForIndex(SBIconListView *list, id metrics, NSUInteger index, BOOL horizontal) {
	if (metrics && [list respondsToSelector:@selector(iconCoordinateForIndex:metrics:)]) {
		JRFIconCoordinate coordinate = [list iconCoordinateForIndex:index metrics:metrics];
		if (MAX(coordinate.first, coordinate.second) == gSlotBase + (NSInteger)index &&
		    MIN(coordinate.first, coordinate.second) == gSlotBase) return coordinate;
	}
	return JRFMakeCoordinate(index, horizontal);
}

// Works out which SBIconCoordinate field is the column (and whether counting starts at 0 or 1).
// Runs while SpringBoard is being asked about a stock dock.
static void JRFCalibrateCoordinates(SBIconListView *list, id metrics, BOOL horizontal, CGFloat iconLength) {
	NSString *how = nil;
	if (metrics && [list respondsToSelector:@selector(iconCoordinateForIndex:metrics:)]) {
		JRFIconCoordinate a = [list iconCoordinateForIndex:0 metrics:metrics];
		JRFIconCoordinate b = [list iconCoordinateForIndex:1 metrics:metrics];
		if (a.first == a.second && (a.first == 0 || a.first == 1)) gSlotBase = a.first;
		BOOL firstChanges = (b.first == a.first + 1 && b.second == a.second);
		BOOL secondChanges = (b.second == a.second + 1 && b.first == a.first);
		if (firstChanges != secondChanges) {
			gColumnIsFirstField = horizontal ? firstChanges : !firstChanges;
			gFieldOrderKnown = YES;
			how = [NSString stringWithFormat:@"from iconCoordinateForIndex (%ld,%ld then %ld,%ld)",
				(long)a.first, (long)a.second, (long)b.first, (long)b.second];
		}
	}
	if (!gFieldOrderKnown && [list respondsToSelector:@selector(originForIconAtCoordinate:numberOfIcons:)]) {
		// Ask the dock for the second slot both ways; the one that moves an app along by one slot is right.
		SBDockIconListView *dock = (SBDockIconListView *)list;
		NSInteger base = gSlotBase;
		JRFIconCoordinate start = { base, base }, firstPlus = { base + 1, base }, secondPlus = { base, base + 1 };
		CGFloat origin = JRFMainOf([dock originForIconAtCoordinate:start numberOfIcons:JRFAppsPerPage], horizontal);
		CGFloat byFirst = JRFMainOf([dock originForIconAtCoordinate:firstPlus numberOfIcons:JRFAppsPerPage], horizontal) - origin;
		CGFloat bySecond = JRFMainOf([dock originForIconAtCoordinate:secondPlus numberOfIcons:JRFAppsPerPage], horizontal) - origin;
		BOOL firstMoves = byFirst > iconLength * 0.5 && byFirst < iconLength * 3.0;
		BOOL secondMoves = bySecond > iconLength * 0.5 && bySecond < iconLength * 3.0;
		if (firstMoves != secondMoves) {
			gColumnIsFirstField = horizontal ? firstMoves : !firstMoves;
			gFieldOrderKnown = YES;
			how = [NSString stringWithFormat:@"from the dock layout (moves %.1f / %.1f pt)", byFirst, bySecond];
		}
	}
	JRFDiagSet(@"coordinate order", [NSString stringWithFormat:@"column is the %@ field, counting from %ld, %@",
		gColumnIsFirstField ? @"first" : @"second", (long)gSlotBase, how ?: @"by iOS version (not confirmed)"]);
}

#pragma mark - Asking SpringBoard how a stock dock is laid out

typedef struct JRFStockMeasurement {
	BOOL metricsValid;        // SpringBoard's metrics for a full stock dock
	CGSize iconSize;
	BOOL slotsMeasured;       // positions for a full dock came from SpringBoard
	BOOL usedDockMethod;      // ...from the dock's own originForIconAtCoordinate:numberOfIcons:
	NSUInteger centredCounts; // bit n: SpringBoard gave nothing usable for n apps, so they were centred
	CGPoint origins[JRFAppsPerPage + 1][JRFAppsPerPage]; // [apps in the dock][slot] -> icon origin
} JRFStockMeasurement;

static BOOL JRFMetricsLookValid(id metrics) {
	if (!metrics || (gMetricsClass && ![metrics isKindOfClass:gMetricsClass])) return NO;
	if (![metrics respondsToSelector:@selector(iconInsets)] || ![metrics respondsToSelector:@selector(alignmentIconSize)] ||
	    ![metrics respondsToSelector:@selector(iconSpacing)]) return NO;
	UIEdgeInsets insets = [(SBIconListViewLayoutMetrics *)metrics iconInsets];
	CGSize icon = [(SBIconListViewLayoutMetrics *)metrics alignmentIconSize];
	CGSize spacing = [(SBIconListViewLayoutMetrics *)metrics iconSpacing];
	return isfinite(insets.top) && isfinite(insets.left) && isfinite(insets.bottom) && isfinite(insets.right) &&
	       icon.width > 1 && icon.height > 1 && isfinite(spacing.width) && isfinite(spacing.height);
}

// Metrics describe a one-page stock dock (when SpringBoard says how many columns and rows they cover).
static BOOL JRFMetricsMatchStock(id metrics, NSUInteger stockLong) {
	if (!JRFMetricsLookValid(metrics)) return NO;
	unsigned long long *columns = JRFIvarPointer(metrics, "_columns", "Q");
	unsigned long long *rows = JRFIvarPointer(metrics, "_rows", "Q");
	if (!columns || !rows) return YES;
	return MAX(*columns, *rows) == stockLong && MIN(*columns, *rows) == 1;
}

static Ivar JRFCachedMetricsIvar(SBIconListView *list) {
	static const char *const names[] = { "_cachedMetrics", "_cachedLayoutMetrics", "_layoutMetrics" };
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		Ivar ivar = JRFFindIvar(list, names[i]);
		const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
		if (type && type[0] == '@') return ivar;
	}
	return NULL;
}

// The list keeps its layout metrics cached; swapping the cache lets SpringBoard's own dock code work from
// stock metrics while it is asked, and clearing it makes SpringBoard work them out again afterwards.
static void JRFSetCachedMetrics(SBIconListView *list, id metrics) {
	Ivar ivar = JRFCachedMetricsIvar(list);
	if (ivar) object_setIvarWithStrongDefault(list, ivar, metrics);
}

static BOOL JRFOriginsLookValid(const CGPoint *origins, NSUInteger count, BOOL horizontal, CGFloat iconLength, CGSize listSize) {
	CGFloat length = JRFMainLength(listSize, horizontal);
	CGFloat crossLength = JRFCrossLength(listSize, horizontal);
	for (NSUInteger i = 0; i < count; i++) {
		CGFloat along = JRFMainOf(origins[i], horizontal);
		CGFloat cross = JRFCrossOf(origins[i], horizontal);
		if (!isfinite(along) || !isfinite(cross)) return NO;
		if (along < -iconLength / 2.0 || along + iconLength > length + iconLength / 2.0) return NO;
		if (cross < -crossLength || cross > crossLength * 2.0) return NO;
		if (i > 0 && along - JRFMainOf(origins[i - 1], horizontal) < iconLength - 0.5) return NO; // in order, no overlap
		if (i > 0 && fabs(cross - JRFCrossOf(origins[0], horizontal)) > 1.0) return NO;          // one row
	}
	return YES;
}

static NSString *JRFDescribeOrigins(const CGPoint *origins, NSUInteger count, BOOL horizontal) {
	NSMutableArray *parts = [NSMutableArray arrayWithCapacity:count];
	for (NSUInteger i = 0; i < count; i++) [parts addObject:[NSString stringWithFormat:@"%.1f", JRFMainOf(origins[i], horizontal)]];
	return [parts componentsJoinedByString:@", "];
}

// Asks SpringBoard's own dock layout code where a normal one-page dock puts 4, 3, 2 and 1 apps.
// The list must be at SpringBoard's single-page size while this runs. Returns the stock metrics, if any.
static id JRFMeasureStockDock(SBIconListView *list, BOOL horizontal, NSUInteger perPage, JRFStockMeasurement *out) {
	memset(out, 0, sizeof(*out));
	SBIconListGridLayoutConfiguration *config = JRFLayoutConfigurationForList(list);
	JRFStockGrid *stock = config ? objc_getAssociatedObject(config, JRFStockGridKey) : nil;
	if (!stock || perPage < 2 || perPage > JRFAppsPerPage) {
		JRFDiagEvent(@"Measuring skipped: %@", stock ? @"unusual dock size" : @"dock layout not seen yet");
		return nil;
	}
	NSUInteger stockLong = MAX(stock.portraitColumns, stock.portraitRows);
	gStockDockModelGrid = (JRFGridSize){ (uint16_t)stock.portraitColumns, (uint16_t)stock.portraitRows };

	BOOL dockMethod = [list respondsToSelector:@selector(originForIconAtCoordinate:numberOfIcons:)];
	BOOL listMethod = [list respondsToSelector:@selector(originForIconAtCoordinate:metrics:)];
	CGSize listSize = list.bounds.size;
	NSString *metricsSource = @"none";

	gStockQueryDepth++;

	// 1. SpringBoard's metrics for a normal 4-app dock: the dock list's own, worked out afresh while the list
	//    is at its stock size and the dock grid and capacity report their stock values.
	JRFSetCachedMetrics(list, nil);
	id metrics = [list respondsToSelector:@selector(layoutMetrics)] ? [list layoutMetrics] : nil;
	if (JRFMetricsMatchStock(metrics, stockLong)) {
		metricsSource = @"dock list";
	} else {
		metrics = nil;
	}
	if (metrics) {
		out->metricsValid = YES;
		out->iconSize = [(SBIconListViewLayoutMetrics *)metrics alignmentIconSize];
		JRFSetCachedMetrics(list, metrics); // the dock's own layout code reads these while it is asked
	}
	CGFloat iconLength = JRFMainLength(metrics ? out->iconSize : JRFIconViewSize(list), horizontal);

	// 2. Which coordinate field is the column.
	JRFCalibrateCoordinates(list, metrics, horizontal, iconLength);

	// 3. Where the dock puts 4, 3, 2 and 1 apps.
	BOOL canPlace = dockMethod || (listMethod && metrics);
	for (NSUInteger count = perPage; canPlace && count >= 1; count--) {
		CGPoint origins[JRFAppsPerPage];
		BOOL valid = dockMethod || count == perPage; // the generic method can't be told how many apps there are
		for (NSUInteger slot = 0; valid && slot < count; slot++) {
			JRFIconCoordinate coordinate = JRFCoordinateForIndex(list, metrics, slot, horizontal);
			origins[slot] = dockMethod ? [(SBDockIconListView *)list originForIconAtCoordinate:coordinate numberOfIcons:count]
			                           : [list originForIconAtCoordinate:coordinate metrics:metrics];
		}
		if (valid) valid = JRFOriginsLookValid(origins, count, horizontal, iconLength, listSize);
		if (valid) {
			for (NSUInteger slot = 0; slot < count; slot++) out->origins[count][slot] = origins[slot];
			JRFDiagSet([NSString stringWithFormat:@"stock positions, %lu app(s)", (unsigned long)count],
				JRFDescribeOrigins(origins, count, horizontal));
		} else if (count == perPage) {
			canPlace = NO;
			JRFDiagEvent(@"Fallback: SpringBoard's own dock positions didn't look right (%@)", JRFDescribeOrigins(origins, count, horizontal));
		} else {
			// Centre the apps with the stock spacing, the way the dock centres fewer apps.
			CGFloat pitch = JRFMainOf(out->origins[perPage][1], horizontal) - JRFMainOf(out->origins[perPage][0], horizontal);
			CGFloat shift = JRFRoundToPixel((perPage - count) * pitch / 2.0, JRFScreenScale(list));
			for (NSUInteger slot = 0; slot < count; slot++) {
				out->origins[count][slot] = JRFShiftAlong(out->origins[perPage][slot], horizontal, shift);
			}
			out->centredCounts |= (1UL << count);
		}
		if (count == 1) break;
	}
	out->slotsMeasured = canPlace;
	out->usedDockMethod = canPlace && dockMethod;

	// 4. What SpringBoard's point-to-slot methods return for the first slot (0- or 1-based).
	if (canPlace && metrics) {
		CGSize size = JRFIconViewSize(list);
		CGPoint center = CGPointMake(out->origins[perPage][0].x + size.width / 2.0, out->origins[perPage][0].y + size.height / 2.0);
		if (horizontal && !gColumnAtPointBaseKnown && [list respondsToSelector:@selector(columnAtPoint:metrics:fractionOfDistanceThroughColumn:)]) {
			NSInteger value = (NSInteger)[list columnAtPoint:center metrics:metrics fractionOfDistanceThroughColumn:NULL];
			if (value == 0 || value == 1) {
				gColumnAtPointBase = value;
				gColumnAtPointBaseKnown = YES;
			}
		}
		if (!horizontal && !gRowAtPointBaseKnown && [list respondsToSelector:@selector(rowAtPoint:metrics:)]) {
			NSInteger value = (NSInteger)[list rowAtPoint:center metrics:metrics];
			if (value == 0 || value == 1) {
				gRowAtPointBase = value;
				gRowAtPointBaseKnown = YES;
			}
		}
	}

	JRFSetCachedMetrics(list, nil); // SpringBoard works out the long row's metrics again from here
	gStockQueryDepth--;

	JRFDiagSet(@"stock metrics", metrics ? [NSString stringWithFormat:@"from %@, app %.1f x %.1f pt", metricsSource, out->iconSize.width, out->iconSize.height]
	                                     : @"not available");
	JRFDiagSet(@"stock positions from", canPlace ? (out->usedDockMethod ? @"the dock's layout method (numberOfIcons)" : @"the icon list layout method (metrics)")
	                                             : @"not available, spacing apps evenly instead");
	return metrics;
}

#pragma mark - Dock state

@class JRFDockState;
static NSHashTable<JRFDockState *> *gDockStates;
static const void *JRFDockStateKey = &JRFDockStateKey;
static const void *JRFListStateKey = &JRFListStateKey;
static BOOL gDockOperating = NO; // the paged dock has been set up at least once

@interface JRFWeakBox : NSObject
@property (nonatomic, weak) id object;
@end

@implementation JRFWeakBox
@end

// Clips the pages to the dock background. Touches in its margins beside the page still drive the pager.
@interface JRFClipView : UIView
@property (nonatomic, weak) UIScrollView *pagingView;
@end

@implementation JRFClipView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	UIView *hit = [super hitTest:point withEvent:event];
	if (hit != self) return hit;
	UIScrollView *pager = self.pagingView;
	return (pager && pager.scrollEnabled && pager.userInteractionEnabled) ? pager : nil;
}
@end

@interface JRFDockState : NSObject <UIScrollViewDelegate> {
@public
	CGPoint _slotOrigins[JRFAppsPerPage + 1][JRFAppsPerPage]; // [apps on the page][slot] -> origin on page 0 (list coordinates)
}
@property (nonatomic, weak) UIView *dockView;
@property (nonatomic, weak) UIView *hostView;        // the list's original superview, where the clip view lives
@property (nonatomic, weak) SBIconListView *listView;
@property (nonatomic, strong) JRFClipView *clipView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) id stockMetrics;       // SpringBoard's metrics for a full stock dock
@property (nonatomic) CGRect stockListFrame;         // what SpringBoard wants for one dock page (host coordinates)
@property (nonatomic) CGRect appliedListFrame;       // what we gave the list (scroll view coordinates)
@property (nonatomic) BOOL hasStockFrame;
@property (nonatomic) BOOL geometryValid;
@property (nonatomic) BOOL horizontal;
@property (nonatomic) BOOL forSnapshot;
@property (nonatomic) BOOL didPlaceInitialPage;
@property (nonatomic) BOOL needsOffsetAlignment;
@property (nonatomic) BOOL needsLayoutCheck;
@property (nonatomic) BOOL inLayout;
@property (nonatomic) BOOL relayoutPending;          // a dock layout was asked for on the next run loop turn
@property (nonatomic) BOOL measured;                 // positions came from SpringBoard (not evenly spaced)
@property (nonatomic) BOOL homeAligned;              // positions line up with the Home Screen's columns
@property (nonatomic) NSUInteger homeAttempts;       // tries at finding the Home Screen's columns
@property (nonatomic) CFTimeInterval lastHomeAttempt;
@property (nonatomic) CGSize measuredSize;           // stock list size the geometry was worked out at
@property (nonatomic) NSInteger measuredOrientation;
@property (nonatomic) BOOL measurementValid;
@property (nonatomic) NSUInteger measureAttempts;
@property (nonatomic) NSUInteger measureIconCount;
@property (nonatomic) BOOL hasStockIconCross;        // where SpringBoard put the app row before we took over
@property (nonatomic) CGFloat stockIconCross;
@property (nonatomic) CGFloat pageZero;              // where page 0 starts along the list (never negative)
@property (nonatomic) CGFloat listShift;             // how far the list starts before SpringBoard's stock frame
@property (nonatomic) CGFloat pageLength;            // one page along the dock
@property (nonatomic) CGFloat pitch;                 // from one app to the next
@property (nonatomic) CGFloat iconLength;            // app icon view size along the dock
@property (nonatomic) CGFloat iconBottom;            // bottom of the dock apps (dock coordinates), 0 if unknown
@property (nonatomic) NSUInteger iconsPerPage;
@property (nonatomic) NSUInteger maxPages;
@property (nonatomic) NSUInteger pagesShown;
@property (nonatomic) NSUInteger originHits;         // how often SpringBoard asked us where an app goes
@property (nonatomic) NSUInteger correctedApps;      // apps moved back into place after SpringBoard's layout
@property (nonatomic) NSInteger edgeDirection;
@property (nonatomic, strong) NSTimer *edgeTimer;
@property (nonatomic) CFTimeInterval lastDragUpdate;
@property (nonatomic) CFTimeInterval lastPageRefresh;
- (CGFloat)mainOffset;
- (void)setMainOffset:(CGFloat)value animated:(BOOL)animated;
- (NSInteger)currentPage;
- (void)updatePageControl;
- (void)refreshPagesAnimated:(BOOL)animated;
- (void)refreshPagesEditing:(BOOL)editing animated:(BOOL)animated;
- (void)updateEdgeDirection:(NSInteger)direction;
- (void)cancelEdgePaging;
- (void)flipTowardEdge;
@end

static void JRFLayoutPageControl(JRFDockState *state);

static BOOL JRFDockIsEditing(SBIconListView *list) {
	// The dock list's own state follows jiggle mode exactly. (The icon manager's can still say "editing"
	// for a moment after jiggle mode ends, which used to leave the spare empty page behind.)
	if ([list respondsToSelector:@selector(isEditing)]) return [list isEditing];
	Class controllerClass = objc_getClass("SBIconController");
	SBIconController *controller = [controllerClass respondsToSelector:@selector(sharedInstance)] ? [controllerClass sharedInstance] : nil;
	SBHIconManager *manager = [controller respondsToSelector:@selector(iconManager)] ? [controller iconManager] : nil;
	return [manager respondsToSelector:@selector(isEditing)] && [manager isEditing];
}

// The on-screen dock (as opposed to snapshot copies SpringBoard makes for transitions).
static JRFDockState *JRFLiveDockState(void) {
	for (JRFDockState *state in gDockStates) {
		if (!state.forSnapshot && state.geometryValid && state.clipView.window) return state;
	}
	return nil;
}

@implementation JRFDockState

- (void)dealloc {
	[_edgeTimer invalidate];
}

- (CGFloat)mainOffset {
	CGPoint offset = self.scrollView.contentOffset;
	return self.horizontal ? offset.x : offset.y;
}

- (void)setMainOffset:(CGFloat)value animated:(BOOL)animated {
	CGPoint offset = self.horizontal ? CGPointMake(value, 0) : CGPointMake(0, value);
	[self.scrollView setContentOffset:offset animated:animated];
}

- (NSInteger)currentPage {
	if (!(self.pageLength > 0) || self.pagesShown == 0) return 0;
	NSInteger page = lround([self mainOffset] / self.pageLength);
	return MAX(0, MIN(page, (NSInteger)self.pagesShown - 1));
}

- (void)updatePageControl {
	UIPageControl *dots = self.pageControl;
	if (dots.numberOfPages != (NSInteger)self.pagesShown) dots.numberOfPages = (NSInteger)self.pagesShown;
	NSInteger page = [self currentPage];
	if (dots.currentPage != page) dots.currentPage = page;
}

- (void)refreshPagesAnimated:(BOOL)animated {
	[self refreshPagesEditing:JRFDockIsEditing(self.listView) animated:animated];
}

// Pages come and go with the apps: as many as the apps fill, plus, in jiggle mode, an empty one after a
// full last page so there is always somewhere to drop.
- (void)refreshPagesEditing:(BOOL)editing animated:(BOOL)animated {
	SBIconListView *list = self.listView;
	if (!list || !self.geometryValid || !(self.pageLength > 0)) return;

	NSUInteger perPage = MAX(self.iconsPerPage, (NSUInteger)1);
	NSUInteger count = JRFIconCount(list);
	NSUInteger pages = editing ? count / perPage + 1 : (count + perPage - 1) / perPage;
	pages = MAX((NSUInteger)1, MIN(pages, self.maxPages));
	BOOL pagesChanged = (pages != self.pagesShown);
	self.pagesShown = pages;

	UIScrollView *scroll = self.scrollView;
	CGSize boundsSize = scroll.bounds.size;
	CGSize contentSize = self.horizontal ? CGSizeMake(pages * self.pageLength, boundsSize.height)
	                                     : CGSizeMake(boundsSize.width, pages * self.pageLength);
	if (!CGSizeEqualToSize(scroll.contentSize, contentSize)) scroll.contentSize = contentSize;

	CGFloat maxOffset = MAX((CGFloat)0, (CGFloat)(pages - 1) * self.pageLength);
	JRFDockState *live = self.forSnapshot ? JRFLiveDockState() : nil;
	if (live && live != self) {
		// Snapshot docks show whatever page the real dock is on.
		CGFloat target = MIN((CGFloat)[live currentPage] * self.pageLength, maxOffset);
		if (fabs(target - [self mainOffset]) > 0.5) [self setMainOffset:target animated:NO];
		self.didPlaceInitialPage = YES;
	} else if (!self.didPlaceInitialPage) {
		self.didPlaceInitialPage = YES;
		[self setMainOffset:0 animated:NO];
	} else if (!scroll.dragging && !scroll.decelerating) {
		CGFloat current = [self mainOffset];
		if (current > maxOffset + 0.5) {
			// The page we were on went away (e.g. jiggle mode ended on the spare page).
			[self setMainOffset:maxOffset animated:animated];
		} else if (self.needsOffsetAlignment) {
			// The page width changed: stay on the same page. (Not done otherwise, so animated page changes
			// in flight are never pulled back.)
			CGFloat target = MIN(MAX((CGFloat)0, lround(current / self.pageLength) * self.pageLength), maxOffset);
			if (fabs(target - current) > 0.5) [self setMainOffset:target animated:NO];
		}
		self.needsOffsetAlignment = NO;
	}

	[self updatePageControl];
	if (pagesChanged) JRFLayoutPageControl(self);
}

#pragma mark Edge paging while dragging an app

- (void)updateEdgeDirection:(NSInteger)direction {
	if (direction == self.edgeDirection) return;
	[self cancelEdgePaging];
	if (direction == 0) return;
	self.edgeDirection = direction;
	__weak JRFDockState *weakSelf = self;
	NSTimer *timer = [NSTimer timerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) {
		[weakSelf flipTowardEdge];
	}];
	[[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
	self.edgeTimer = timer;
}

- (void)cancelEdgePaging {
	[self.edgeTimer invalidate];
	self.edgeTimer = nil;
	self.edgeDirection = 0;
}

- (void)flipTowardEdge {
	if (!JRFDockIsEditing(self.listView) || !self.clipView.window || CACurrentMediaTime() - self.lastDragUpdate > 4.0) {
		[self cancelEdgePaging];
		return;
	}
	if (self.scrollView.dragging) return;
	NSInteger target = [self currentPage] + self.edgeDirection;
	if (target < 0 || target >= (NSInteger)self.pagesShown) return;
	[self setMainOffset:target * self.pageLength animated:YES];
}

#pragma mark UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
	[self updatePageControl];
}

@end

static JRFDockState *JRFStateForDock(UIView *dock, BOOL create) {
	JRFDockState *state = objc_getAssociatedObject(dock, JRFDockStateKey);
	if (state || !create) return state;

	state = [JRFDockState new];
	state.dockView = dock;
	state.appliedListFrame = CGRectNull;

	JRFClipView *clip = [[JRFClipView alloc] initWithFrame:CGRectZero];
	clip.clipsToBounds = YES;
	clip.backgroundColor = UIColor.clearColor;

	UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
	scroll.pagingEnabled = YES;
	scroll.clipsToBounds = NO;
	scroll.showsHorizontalScrollIndicator = NO;
	scroll.showsVerticalScrollIndicator = NO;
	scroll.scrollsToTop = NO;
	scroll.directionalLockEnabled = YES;
	scroll.delaysContentTouches = NO;
	scroll.canCancelContentTouches = YES;
	scroll.alwaysBounceHorizontal = NO;
	scroll.alwaysBounceVertical = NO;
	scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
	scroll.backgroundColor = UIColor.clearColor;
	scroll.delegate = state;
	[clip addSubview:scroll];
	clip.pagingView = scroll;

	UIPageControl *dots = [[UIPageControl alloc] initWithFrame:CGRectZero];
	dots.hidesForSinglePage = YES;
	dots.userInteractionEnabled = NO; // never steal touches from the apps
	dots.backgroundStyle = UIPageControlBackgroundStyleMinimal;
	dots.currentPageIndicatorTintColor = [UIColor.labelColor colorWithAlphaComponent:0.85];
	dots.pageIndicatorTintColor = [UIColor.labelColor colorWithAlphaComponent:0.28];
	dots.hidden = YES;
	dots.transform = CGAffineTransformMakeScale(0.7, 0.7); // set once; bounds and center are unaffected by it
	dots.layer.zPosition = 1000; // drawn above the dock without ever reordering the dock's subviews

	state.clipView = clip;
	state.scrollView = scroll;
	state.pageControl = dots;
	objc_setAssociatedObject(dock, JRFDockStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[gDockStates addObject:state];
	return state;
}

static JRFDockState *JRFStateForListView(id list) {
	if (!JRFIsDockListView(list)) return nil;
	JRFWeakBox *box = objc_getAssociatedObject(list, JRFListStateKey);
	JRFDockState *state = box.object;
	return (state && state.listView == list) ? state : nil;
}

static SBIconListView *JRFFindDockList(UIView *view, NSUInteger depth) {
	for (UIView *subview in view.subviews) {
		if (JRFIsDockListView(subview)) return (SBIconListView *)subview;
	}
	if (depth == 0) return nil;
	for (UIView *subview in view.subviews) {
		SBIconListView *found = JRFFindDockList(subview, depth - 1);
		if (found) return found;
	}
	return nil;
}

static SBIconListView *JRFListViewForDock(UIView *dock) {
	JRFDockState *state = JRFStateForDock(dock, NO);
	if (JRFIsDockListView(state.listView)) return state.listView;
	id list = JRFObjectIvar(dock, "_iconListView");
	if (!JRFIsDockListView(list) && [dock respondsToSelector:@selector(dockListView)]) list = [(SBDockView *)dock dockListView];
	if (!JRFIsDockListView(list)) list = JRFFindDockList(dock, 3);
	return JRFIsDockListView(list) ? list : nil;
}

static UIView *JRFDockBackground(UIView *dock) {
	UIView *background = [dock respondsToSelector:@selector(backgroundView)] ? [(SBDockView *)dock backgroundView] : nil;
	if (![background isKindOfClass:[UIView class]]) background = JRFObjectIvar(dock, "_backgroundView");
	return ([background isKindOfClass:[UIView class]] && background.superview) ? background : nil;
}

// The dock background ("platter"), in `view`'s coordinates.
static CGRect JRFPlatterFrame(UIView *dock, UIView *view) {
	UIView *background = JRFDockBackground(dock);
	if (!background || !view) return CGRectNull;
	CGRect frame = [background.superview convertRect:background.frame toView:view];
	return (frame.size.width > 1 && frame.size.height > 1 && isfinite(frame.origin.x) && isfinite(frame.origin.y)) ? frame : CGRectNull;
}

static void JRFLayoutPageControl(JRFDockState *state) {
	UIView *dock = state.dockView;
	UIPageControl *dots = state.pageControl;
	if (!dock) return;
	if (dots.superview != dock) [dock addSubview:dots];

	BOOL show = gShowDots && state.geometryValid && state.horizontal && !state.forSnapshot && state.pagesShown > 1 && JRFActive();
	if (dots.hidden == show) dots.hidden = !show;
	if (!show) return;
	[state updatePageControl];

	CGRect platter = JRFPlatterFrame(dock, dock);
	CGFloat bottom = CGRectIsNull(platter) ? CGRectGetMaxY(dock.bounds) : CGRectGetMaxY(platter);
	CGFloat centerY = bottom - 8.0;
	if (state.iconBottom > 0 && bottom - state.iconBottom > 6.0) {
		centerY = state.iconBottom + MIN((CGFloat)10.0, (bottom - state.iconBottom) / 2.0);
	}
	CGRect clip = [state.clipView.superview convertRect:state.clipView.frame toView:dock];
	CGSize size = [dots sizeForNumberOfPages:(NSInteger)state.pagesShown];
	CGRect bounds = CGRectMake(0, 0, size.width, size.height);
	CGPoint center = CGPointMake(CGRectGetMidX(clip), centerY);
	// Only touch geometry that actually changes, so this never feeds back into the dock's layout.
	if (!CGRectEqualToRect(dots.bounds, bounds)) dots.bounds = bounds;
	if (fabs(dots.center.x - center.x) > 0.25 || fabs(dots.center.y - center.y) > 0.25) dots.center = center;
}

// Pins SpringBoard's layout metrics for the long row to the stock dock: stock gap, icon size and edge
// insets, and no re-centring of a row that isn't full.
static void JRFPatchDockMetrics(id metrics, JRFDockState *state) {
	if (!metrics || !state.geometryValid || JRFStockQueryActive()) return;
	if (gMetricsClass && ![metrics isKindOfClass:gMetricsClass]) return;
	BOOL horizontal = state.horizontal;
	NSUInteger slots = state.iconsPerPage * state.maxPages;
	CGFloat gap = MAX((CGFloat)0, state.pitch - state.iconLength);
	CGFloat lead = JRFMainOf(state->_slotOrigins[state.iconsPerPage][0], horizontal);
	CGFloat listLength = JRFMainLength(state.appliedListFrame.size, horizontal);
	CGFloat trail = MAX((CGFloat)0, listLength - lead - slots * state.iconLength - (slots - 1) * gap);

	CGSize *spacing = JRFIvarPointer(metrics, "_iconSpacing", "{CGSize");
	if (spacing) {
		if (horizontal) spacing->width = gap;
		else spacing->height = gap;
	}
	UIEdgeInsets *insets = JRFIvarPointer(metrics, "_iconInsets", "{UIEdgeInsets");
	if (insets && listLength > 0) {
		if (horizontal) {
			insets->left = lead;
			insets->right = trail;
		} else {
			insets->top = lead;
			insets->bottom = trail;
		}
	}

	id stock = state.stockMetrics;
	if (stock && stock != metrics) {
		static const char *const sizeIvars[] = { "_iconSize", "_alignmentIconSize", "_iconImageSize" };
		for (size_t i = 0; i < sizeof(sizeIvars) / sizeof(sizeIvars[0]); i++) {
			CGSize *from = JRFIvarPointer(stock, sizeIvars[i], "{CGSize");
			CGSize *to = JRFIvarPointer(metrics, sizeIvars[i], "{CGSize");
			if (from && to) *to = *from;
		}
		double *fromScale = JRFIvarPointer(stock, "_iconContentScale", "d");
		double *toScale = JRFIvarPointer(metrics, "_iconContentScale", "d");
		if (fromScale && toScale && *fromScale > 0) *toScale = *fromScale;
	}

	if (horizontal) {
		unsigned long long *used = JRFIvarPointer(metrics, "_columnsUsedForLayout", "Q");
		if (used && *used > 0 && *used < slots) *used = slots;
		long long *offset = JRFIvarPointer(metrics, "_columnOffset", "q");
		if (offset) *offset = 0;
	}
}

static void JRFEnsureVisibleColumns(SBIconListView *list, NSUInteger slots) {
	if (![list respondsToSelector:@selector(visibleColumnRange)] || ![list respondsToSelector:@selector(setVisibleColumnRange:)]) return;
	NSRange range = [list visibleColumnRange];
	if (range.location != NSNotFound && range.length > 0 && range.length < 10000 && NSMaxRange(range) < slots) {
		[list setVisibleColumnRange:NSMakeRange(0, slots)];
	}
}

// Shows the list as a single plain page (only if no stock frame is known yet).
static void JRFApplySinglePageFallback(UIView *host, SBIconListView *list, JRFDockState *state) {
	CGRect stock = state.hasStockFrame ? state.stockListFrame : host.bounds;
	state.geometryValid = NO;
	state.clipView.frame = stock;
	state.scrollView.frame = state.clipView.bounds;
	state.scrollView.contentSize = stock.size;
	state.scrollView.contentOffset = CGPointZero;
	list.frame = CGRectMake(0, 0, stock.size.width, stock.size.height);
	state.appliedListFrame = list.frame;
	state.pageControl.hidden = YES;
}

// Evenly spaced positions (each app centred in a quarter of the dock background), used only when
// SpringBoard's own positions can't be measured. Pages with fewer apps are centred.
static void JRFEstimateSlots(JRFDockState *state, SBIconListView *list, CGRect stock, CGRect platter, BOOL horizontal, NSUInteger perPage, CGFloat scale) {
	CGSize iconSize = JRFIconViewSize(list);
	CGFloat iconLength = JRFMainLength(iconSize, horizontal);
	CGFloat stockMain = horizontal ? stock.origin.x : stock.origin.y;
	CGFloat stockLength = JRFMainLength(stock.size, horizontal);
	CGFloat pageStart = stockMain, pageWidth = stockLength;
	if (!CGRectIsNull(platter)) {
		CGFloat platterStart = horizontal ? platter.origin.x : platter.origin.y;
		CGFloat platterLength = JRFMainLength(platter.size, horizontal);
		if (platterLength >= stockLength * 0.8 && platterLength >= perPage * iconLength) {
			pageStart = platterStart;
			pageWidth = platterLength;
		}
	}
	CGFloat slotWidth = MAX(pageWidth / perPage, iconLength);
	CGFloat cross = state.hasStockIconCross ? state.stockIconCross
	                                        : JRFRoundToPixel((JRFCrossLength(stock.size, horizontal) - JRFCrossLength(iconSize, horizontal)) / 2.0, scale);
	CGFloat pageZero = pageStart - stockMain; // list coordinates
	for (NSUInteger count = 1; count <= perPage; count++) {
		for (NSUInteger slot = 0; slot < count; slot++) {
			CGFloat center = pageZero + slotWidth * ((CGFloat)slot + 0.5 + (CGFloat)(perPage - count) / 2.0);
			state->_slotOrigins[count][slot] = JRFPointAlong(horizontal, JRFRoundToPixel(center - iconLength / 2.0, scale), cross);
		}
	}
	state.iconLength = iconLength;
	state.pitch = slotWidth;
	state.pageZero = pageZero;
	state.pageLength = JRFRoundToPixel(slotWidth * perPage, scale);
}

// The Home Screen's pages (icon lists), the current one first. The stock dock lines its apps up with their
// columns.
static NSArray<SBIconListView *> *JRFHomeScreenLists(void) {
	Class controllerClass = objc_getClass("SBIconController");
	SBIconController *controller = [controllerClass respondsToSelector:@selector(sharedInstance)] ? [controllerClass sharedInstance] : nil;
	SBHIconManager *manager = [controller respondsToSelector:@selector(iconManager)] ? [controller iconManager] : nil;
	JRFFolderControllerStandIn *root = [manager respondsToSelector:@selector(rootFolderController)] ? [manager rootFolderController] : nil;
	NSMutableArray *candidates = [NSMutableArray array];
	if ([root respondsToSelector:@selector(currentIconListView)]) {
		id current = [root currentIconListView];
		if (current) [candidates addObject:current];
	}
	if ([root respondsToSelector:@selector(iconListViews)]) {
		id lists = [root iconListViews];
		if ([lists isKindOfClass:[NSArray class]]) [candidates addObjectsFromArray:lists];
	}
	Class listClass = objc_getClass("SBIconListView");
	NSMutableArray<SBIconListView *> *found = [NSMutableArray array];
	for (id candidate in candidates) {
		if (!listClass || ![candidate isKindOfClass:listClass] || JRFIsDockListView(candidate)) continue;
		if ([found indexOfObjectIdenticalTo:candidate] != NSNotFound) continue;
		SBIconListView *list = candidate;
		if (list.bounds.size.width < 200) continue; // not laid out (e.g. a hidden page)
		[found addObject:list];
	}
	return found;
}

// Evenly spaced columns, a believable distance apart.
static BOOL JRFColumnsLookRight(const CGFloat *xs, NSUInteger count) {
	if (count < 2) return NO;
	CGFloat pitch = (xs[count - 1] - xs[0]) / (CGFloat)(count - 1);
	if (!(pitch >= 40.0) || pitch > 200.0) return NO;
	for (NSUInteger i = 1; i < count; i++) {
		if (!isfinite(xs[i]) || fabs((xs[i] - xs[i - 1]) - pitch) > 1.5) return NO;
	}
	return YES;
}

// 1. Where a page's own apps are: the centres of its app icons, grouped into columns. Widgets are ignored,
//    so a page needs apps in every column. Results are offsets from the middle of the page.
static BOOL JRFColumnsFromApps(SBIconListView *list, NSUInteger columns, CGFloat *offsets) {
	if (!gIconViewClass) return NO;
	CGFloat middle = CGRectGetMidX(list.bounds);
	NSMutableArray<NSNumber *> *xs = [NSMutableArray array];
	for (UIView *view in list.subviews) {
		if (![view isKindOfClass:gIconViewClass] || view.hidden || ![view respondsToSelector:@selector(icon)]) continue;
		id icon = [(SBIconView *)view icon];
		if (!icon || ([icon respondsToSelector:@selector(gridSizeClass)] && [(SBIcon *)icon gridSizeClass] != 0)) continue;
		CGFloat width = view.bounds.size.width;
		if (width < 20 || width > 140) continue;
		[xs addObject:@(view.center.x - middle)];
	}
	[xs sortUsingSelector:@selector(compare:)];
	NSMutableArray<NSNumber *> *centres = [NSMutableArray array];
	CGFloat sum = 0, last = 0;
	NSUInteger inColumn = 0;
	for (NSNumber *value in xs) {
		CGFloat x = value.doubleValue;
		if (inColumn > 0 && x - last > 3.0) {
			[centres addObject:@(sum / inColumn)];
			sum = 0;
			inColumn = 0;
		}
		sum += x;
		inColumn++;
		last = x;
	}
	if (inColumn > 0) [centres addObject:@(sum / inColumn)];
	if (centres.count != columns) return NO;
	CGFloat values[JRFAppsPerPage];
	for (NSUInteger i = 0; i < columns; i++) values[i] = centres[i].doubleValue;
	if (!JRFColumnsLookRight(values, columns)) return NO;
	memcpy(offsets, values, sizeof(CGFloat) * columns);
	return YES;
}

// 2. SpringBoard's grid for the page, on a row without a widget (empty cells and apps give the plain
//    column positions), bottom row first since widgets usually sit at the top.
static BOOL JRFColumnsFromGrid(SBIconListView *list, NSUInteger columns, CGFloat *offsets) {
	BOOL byCenter = [list respondsToSelector:@selector(centerForIconCoordinate:metrics:)];
	if (!byCenter && ![list respondsToSelector:@selector(originForIconAtCoordinate:metrics:)]) return NO;
	if (![list respondsToSelector:@selector(layoutMetrics)]) return NO;
	id metrics = [list layoutMetrics];
	if (!JRFMetricsLookValid(metrics)) return NO;
	CGFloat iconWidth = [(SBIconListViewLayoutMetrics *)metrics alignmentIconSize].width;
	unsigned long long *rowCount = JRFIvarPointer(metrics, "_rows", "Q");
	NSInteger rows = (rowCount && *rowCount > 0 && *rowCount < 20) ? (NSInteger)*rowCount : 6;
	CGFloat middle = CGRectGetMidX(list.bounds);
	for (NSInteger row = rows; row >= 1; row--) {
		for (int attempt = 0; attempt < 2; attempt++) {
			BOOL columnFirst = (attempt == 0) ? gColumnIsFirstField : !gColumnIsFirstField;
			CGFloat xs[JRFAppsPerPage], y0 = 0;
			BOOL ok = YES;
			for (NSUInteger i = 0; i < columns && ok; i++) {
				NSInteger column = gSlotBase + (NSInteger)i, rowValue = gSlotBase + row - 1;
				JRFIconCoordinate coordinate = columnFirst ? (JRFIconCoordinate){ column, rowValue } : (JRFIconCoordinate){ rowValue, column };
				CGPoint point;
				if (byCenter) {
					point = [list centerForIconCoordinate:coordinate metrics:metrics];
				} else {
					CGPoint origin = [list originForIconAtCoordinate:coordinate metrics:metrics];
					point = CGPointMake(origin.x + iconWidth / 2.0, origin.y);
				}
				if (!isfinite(point.x) || !isfinite(point.y)) ok = NO;
				if (i == 0) y0 = point.y;
				else if (fabs(point.y - y0) > 1.0) ok = NO;
				xs[i] = point.x - middle;
			}
			if (ok && JRFColumnsLookRight(xs, columns)) {
				memcpy(offsets, xs, sizeof(CGFloat) * columns);
				return YES;
			}
		}
	}
	return NO;
}

// 3. The grid's own numbers: edge inset, app size and spacing.
static BOOL JRFColumnsFromMetrics(SBIconListView *list, NSUInteger columns, CGFloat *offsets) {
	if (![list respondsToSelector:@selector(layoutMetrics)]) return NO;
	id metrics = [list layoutMetrics];
	if (!JRFMetricsLookValid(metrics)) return NO;
	UIEdgeInsets insets = [(SBIconListViewLayoutMetrics *)metrics iconInsets];
	CGFloat width = [(SBIconListViewLayoutMetrics *)metrics alignmentIconSize].width;
	CGFloat spacing = [(SBIconListViewLayoutMetrics *)metrics iconSpacing].width;
	CGRect bounds = list.bounds;
	CGFloat xs[JRFAppsPerPage];
	for (NSUInteger i = 0; i < columns; i++) {
		xs[i] = CGRectGetMinX(bounds) + insets.left + (CGFloat)i * (width + spacing) + width / 2.0 - CGRectGetMidX(bounds);
	}
	if (!JRFColumnsLookRight(xs, columns)) return NO;
	if (xs[0] < -bounds.size.width / 2.0 || xs[columns - 1] > bounds.size.width / 2.0) return NO;
	memcpy(offsets, xs, sizeof(CGFloat) * columns);
	return YES;
}

// The Home Screen's first `columns` columns, as offsets from the middle of a page.
static BOOL JRFHomeColumnOffsets(NSUInteger columns, CGFloat *offsets, NSString **how) {
	if (columns < 2 || columns > JRFAppsPerPage) return NO;
	NSArray<SBIconListView *> *lists = JRFHomeScreenLists();
	if (lists.count == 0) {
		*how = @"no Home Screen page found yet";
		return NO;
	}
	static NSString *const sources[] = { @"the apps on", @"SpringBoard's grid for", @"the grid spacing of" };
	for (int method = 0; method < 3; method++) {
		NSUInteger checked = 0;
		for (SBIconListView *list in lists) {
			checked++;
			BOOL ok = method == 0 ? JRFColumnsFromApps(list, columns, offsets)
			        : method == 1 ? JRFColumnsFromGrid(list, columns, offsets)
			                      : JRFColumnsFromMetrics(list, columns, offsets);
			if (ok) {
				NSMutableArray *parts = [NSMutableArray array];
				CGFloat middle = list.bounds.size.width / 2.0;
				for (NSUInteger i = 0; i < columns; i++) [parts addObject:[NSString stringWithFormat:@"%.1f", middle + offsets[i]]];
				*how = [NSString stringWithFormat:@"centres %@ from %@ %@ (%lu of %lu pages checked, %.0f pt wide)",
					[parts componentsJoinedByString:@", "], sources[method], checked == 1 ? @"the current page" : @"another page",
					(unsigned long)checked, (unsigned long)lists.count, list.bounds.size.width];
				return YES;
			}
		}
	}
	*how = [NSString stringWithFormat:@"couldn't read the columns of %lu Home Screen page(s)", (unsigned long)lists.count];
	return NO;
}

// The dock's slots lined up with the Home Screen columns: a full page sits exactly under the columns, fewer
// apps are centred with the same spacing (like the stock dock). Positions are in list coordinates.
static BOOL JRFHomeAlignedSlots(JRFDockState *state, UIView *dock, UIView *host, SBIconListView *list, CGRect stock,
                                NSUInteger perPage, CGFloat cross, CGFloat scale, NSString **how) {
	CGFloat offsets[JRFAppsPerPage];
	if (!JRFHomeColumnOffsets(perPage, offsets, how)) return NO;
	// The Home Screen pages and the dock both span the screen, so they line up by their middles (no window
	// coordinates involved, which animations would distort).
	CGFloat dockMid = [dock convertPoint:CGPointMake(CGRectGetMidX(dock.bounds), CGRectGetMidY(dock.bounds)) toView:host].x - stock.origin.x;
	CGFloat iconWidth = JRFIconViewSize(list).width;
	CGFloat pitch = (offsets[perPage - 1] - offsets[0]) / (CGFloat)(perPage - 1);
	CGFloat groupMid = (offsets[0] + offsets[perPage - 1]) / 2.0;
	for (NSUInteger count = 1; count <= perPage; count++) {
		for (NSUInteger slot = 0; slot < count; slot++) {
			CGFloat center = (count == perPage) ? dockMid + offsets[slot]
			                                    : dockMid + groupMid + ((CGFloat)slot - (CGFloat)(count - 1) / 2.0) * pitch;
			state->_slotOrigins[count][slot] = CGPointMake(JRFRoundToPixel(center - iconWidth / 2.0, scale), cross);
		}
	}
	state.iconLength = iconWidth;
	state.pitch = pitch;
	return YES;
}

static JRFRate gTakeoverRate;

static void JRFLayoutDockInner(UIView *dock, SBIconListView *list, JRFDockState *state) {
	// 1. Move the list into the pager (and back in, if SpringBoard ever re-adds it elsewhere).
	if (list.superview != state.scrollView) {
		UIView *parent = list.superview;
		if (!parent) return;
		if (JRFRateExceeded(&gTakeoverRate, JRFMaxTakeoversPer10Seconds, 10.0)) {
			JRFTrip(@"SpringBoard kept moving the dock's apps back out of the pages", [NSString stringWithFormat:
				@"The dock list was taken over more than %d times in 10 seconds (last from %@).",
				JRFMaxTakeoversPer10Seconds, NSStringFromClass([parent class])]);
			return;
		}
		state.hostView = parent;
		if (state.clipView.superview != parent) [parent insertSubview:state.clipView aboveSubview:list];
		state.stockListFrame = list.frame;
		state.hasStockFrame = YES;
		// Where SpringBoard puts the app row, before anything changes.
		for (UIView *view in JRFIconViews(list)) {
			CGRect frame = view.frame;
			if (frame.size.width > 1 && frame.size.height > 1) {
				BOOL horizontal = list.frame.size.width >= list.frame.size.height;
				state.stockIconCross = horizontal ? frame.origin.y : frame.origin.x;
				state.hasStockIconCross = YES;
				break;
			}
		}
		[state.scrollView addSubview:list];
		state.listView = list;
		JRFWeakBox *box = [JRFWeakBox new];
		box.object = state;
		objc_setAssociatedObject(list, JRFListStateKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		state.appliedListFrame = CGRectNull;
		JRFDiagEvent(@"Took over the dock list (%@ in %@), stock frame %@", NSStringFromClass([list class]),
			NSStringFromClass([parent class]), NSStringFromCGRect(state.stockListFrame));
	} else if (!JRFRectsClose(list.frame, state.appliedListFrame)) {
		// SpringBoard just sized the list for one stock dock.
		state.stockListFrame = list.frame;
		state.hasStockFrame = YES;
	}

	UIView *host = state.hostView ?: dock;
	CGRect stock = state.stockListFrame;
	if (!state.hasStockFrame || !(stock.size.width > 0) || !(stock.size.height > 0)) {
		JRFApplySinglePageFallback(host, list, state);
		return;
	}

	BOOL horizontal = stock.size.width >= stock.size.height;
	if (horizontal != state.horizontal) {
		state.horizontal = horizontal;
		state.didPlaceInitialPage = NO;
	}
	state.forSnapshot = JRFBoolIvar(dock, "_forSnapshot", NO);

	// 2. Keep SpringBoard's own dock grid and capacity in step with the page count.
	SBIconListGridLayoutConfiguration *config = JRFLayoutConfigurationForList(list);
	BOOL configChanged = config ? JRFPatchDockConfiguration(config) : NO;
	JRFNoteDockModel([list model]);
	JRFRaiseDockModelStorage([list model]);

	NSUInteger perPage = MIN(JRFIconsPerPage(), (NSUInteger)JRFAppsPerPage);
	NSUInteger pages = gPages;
	NSUInteger slots = perPage * pages;
	CGFloat scale = JRFScreenScale(dock);
	CGRect platter = JRFPlatterFrame(dock, host);

	// 3. Work out the pages: measured from SpringBoard when possible, evenly spaced otherwise.
	NSInteger orientation = JRFListOrientation(list);
	NSUInteger iconCount = JRFIconCount(list);
	BOOL retry = !state.measurementValid && state.measureAttempts < 8 && iconCount != state.measureIconCount;
	BOOL retryHome = horizontal && !state.homeAligned && state.homeAttempts < 20 && CACurrentMediaTime() - state.lastHomeAttempt > 0.5;
	BOOL needsMeasure = !state.geometryValid || !CGSizeEqualToSize(state.measuredSize, stock.size) ||
	                    state.measuredOrientation != orientation || state.iconsPerPage != perPage || retry || retryHome;
	if (needsMeasure) {
		CGRect current = list.frame;
		list.frame = CGRectMake(current.origin.x, current.origin.y, stock.size.width, stock.size.height);
		JRFStockMeasurement measurement;
		id stockMetrics = JRFMeasureStockDock(list, horizontal, perPage, &measurement);
		state.measuredSize = stock.size;
		state.measuredOrientation = orientation;
		state.measureIconCount = iconCount;
		state.measurementValid = measurement.slotsMeasured;
		state.measureAttempts = measurement.slotsMeasured ? 0 : state.measureAttempts + 1;
		state.stockMetrics = measurement.metricsValid ? stockMetrics : nil;

		// Where the apps go on a page: under the Home Screen's columns, like the stock dock (horizontal docks).
		// Otherwise SpringBoard's own dock layout as measured, otherwise evenly spaced.
		CGFloat cross = measurement.slotsMeasured ? JRFCrossOf(measurement.origins[perPage][0], horizontal)
		              : state.hasStockIconCross ? state.stockIconCross
		              : JRFRoundToPixel((JRFCrossLength(stock.size, horizontal) - JRFCrossLength(JRFIconViewSize(list), horizontal)) / 2.0, scale);
		NSString *layout = nil, *homeHow = @"not used (vertical dock)";
		BOOL usable = NO;
		state.homeAligned = horizontal && JRFHomeAlignedSlots(state, dock, host, list, stock, perPage, cross, scale, &homeHow);
		if (state.homeAligned) {
			usable = YES;
			layout = @"lined up with the Home Screen columns";
		} else if (horizontal) {
			state.homeAttempts++;
			state.lastHomeAttempt = CACurrentMediaTime();
			if (state.homeAttempts < 20) {
				// The Home Screen may not be laid out yet: look again shortly.
				__weak UIView *weakDock = dock;
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					if (JRFActive()) [weakDock setNeedsLayout];
				});
			}
		}
		if (!usable && measurement.slotsMeasured) {
			CGFloat first = JRFMainOf(measurement.origins[perPage][0], horizontal);
			CGFloat last = JRFMainOf(measurement.origins[perPage][perPage - 1], horizontal);
			CGFloat pitch = (last - first) / (CGFloat)(perPage - 1);
			CGFloat iconLength = JRFMainLength(measurement.metricsValid ? measurement.iconSize : JRFIconViewSize(list), horizontal);
			if (isfinite(pitch) && pitch >= iconLength && iconLength > 1) {
				memcpy(state->_slotOrigins, measurement.origins, sizeof(measurement.origins));
				state.iconLength = iconLength;
				state.pitch = pitch;
				usable = YES;
				layout = measurement.centredCounts ? @"SpringBoard's dock positions (fewer apps centred by the tweak)" : @"SpringBoard's dock positions";
			}
		}
		state.measured = usable;
		if (!usable) {
			JRFEstimateSlots(state, list, stock, platter, horizontal, perPage, scale);
			layout = @"evenly spaced (neither the Home Screen columns nor SpringBoard's dock positions could be read)";
		}

		// A page is the part of the dock background that's on screen (on an iPhone SE the background reaches past
		// both edges), so a swipe moves exactly one dock-width, like Home Screen pages, and a page never shows
		// another page's apps. Without a background (or if the apps don't fit in it), a page spans the apps.
		CGFloat firstMain = JRFMainOf(state->_slotOrigins[perPage][0], horizontal);
		CGFloat lastEnd = JRFMainOf(state->_slotOrigins[perPage][perPage - 1], horizontal) + state.iconLength;
		state.pageZero = firstMain - (state.pitch - state.iconLength) / 2.0;
		state.pageLength = JRFRoundToPixel(perPage * state.pitch, scale);
		CGRect visible = platter;
		if (!CGRectIsNull(platter)) {
			CGRect onScreen = CGRectIntersection(platter, [dock convertRect:dock.bounds toView:host]);
			if (!CGRectIsNull(onScreen) && JRFMainLength(onScreen.size, horizontal) >= perPage * state.iconLength) visible = onScreen;
			CGFloat visibleStart = (horizontal ? visible.origin.x - stock.origin.x : visible.origin.y - stock.origin.y);
			CGFloat visibleLength = JRFMainLength(visible.size, horizontal);
			if (visibleStart <= firstMain + 0.5 && visibleStart + visibleLength >= lastEnd - 0.5) {
				state.pageZero = visibleStart;
				state.pageLength = JRFRoundToPixel(visibleLength, scale);
			}
		}

		// If page 0 starts before the list does (dock background wider than SpringBoard's list), extend the
		// list to the left so every app sits inside it (apps outside their list can't be tapped).
		CGFloat shift = state.pageZero < 0 ? -state.pageZero : 0;
		for (NSUInteger count = 1; shift > 0 && count <= perPage; count++) {
			for (NSUInteger slot = 0; slot < count; slot++) {
				state->_slotOrigins[count][slot] = JRFShiftAlong(state->_slotOrigins[count][slot], horizontal, shift);
			}
		}
		state.pageZero += shift;
		state.listShift = shift;
		JRFDiagSet(@"layout", layout);
		JRFDiagSet(@"home screen columns", homeHow);
		JRFDiagSet(@"dock positions, full page", JRFDescribeOrigins(state->_slotOrigins[perPage], perPage, horizontal));
		JRFDiagSet(@"page geometry", [NSString stringWithFormat:@"page %.2f pt, app %.1f pt, pitch %.2f pt, page 0 starts at %.2f",
			state.pageLength, state.iconLength, state.pitch, state.pageZero]);
	}

	if (!(state.pageLength > state.iconLength) || !(state.iconLength > 1) || !isfinite(state.pageZero)) {
		JRFDiagEvent(@"Couldn't work out the dock pages; showing a single page");
		JRFApplySinglePageFallback(host, list, state);
		return;
	}
	if (state.geometryValid && state.iconsPerPage == perPage && needsMeasure) state.needsOffsetAlignment = YES;
	state.iconsPerPage = perPage;
	state.maxPages = pages;
	state.geometryValid = YES;
	gDockOperating = YES;

	// 4. Frames. Page 0 runs from pageZero to pageZero + pageLength along the list. The list starts at its
	//    stock position (or listShift before it), so page 0 shows exactly where SpringBoard draws the dock.
	CGFloat stockMain = (horizontal ? stock.origin.x : stock.origin.y) - state.listShift;
	CGFloat stockLength = JRFMainLength(stock.size, horizontal) + state.listShift;
	CGFloat stockCross = horizontal ? stock.origin.y : stock.origin.x;
	CGFloat stockCrossLength = JRFCrossLength(stock.size, horizontal);
	CGFloat pageLength = state.pageLength;
	CGFloat pageStart = stockMain + state.pageZero; // host coordinates

	CGRect clipFrame;
	if (!CGRectIsNull(platter)) {
		clipFrame = platter;
	} else {
		CGRect bounds = host.bounds;
		CGFloat crossMin = MIN(horizontal ? CGRectGetMinY(bounds) : CGRectGetMinX(bounds), stockCross);
		CGFloat crossMax = MAX(horizontal ? CGRectGetMaxY(bounds) : CGRectGetMaxX(bounds), stockCross + stockCrossLength);
		clipFrame = JRFRectAlong(horizontal, pageStart, pageLength, crossMin, crossMax - crossMin);
	}
	CGFloat clipMain = horizontal ? clipFrame.origin.x : clipFrame.origin.y;
	CGFloat clipCross = horizontal ? clipFrame.origin.y : clipFrame.origin.x;
	CGFloat clipCrossLength = JRFCrossLength(clipFrame.size, horizontal);
	CGFloat listLength = MAX(stockLength, state.pageZero + pages * pageLength + MAX((CGFloat)0, stockLength - state.pageZero - pageLength));

	CGRect scrollFrame = JRFRectAlong(horizontal, pageStart - clipMain, pageLength, 0, clipCrossLength);
	CGRect listFrame = JRFRectAlong(horizontal, -state.pageZero, listLength, stockCross - clipCross, stockCrossLength);

	BOOL framesChanged = !JRFRectsClose(state.clipView.frame, clipFrame) ||
	                     !JRFRectsClose(state.scrollView.frame, scrollFrame) ||
	                     !JRFRectsClose(state.appliedListFrame, listFrame);
	// Only set what differs: setting geometry that hasn't changed can still invalidate layout.
	if (!JRFRectsClose(state.clipView.frame, clipFrame)) state.clipView.frame = clipFrame;
	if (!JRFRectsClose(state.scrollView.frame, scrollFrame)) state.scrollView.frame = scrollFrame;
	if (!JRFRectsClose(list.frame, listFrame)) list.frame = listFrame; // SpringBoard just set its one-page frame
	state.appliedListFrame = list.frame;
	if (state.scrollView.scrollEnabled == state.forSnapshot) state.scrollView.scrollEnabled = !state.forSnapshot;

	// Round the clip like the dock background, so apps slide under its curved ends.
	UIView *background = JRFDockBackground(dock);
	CGFloat radius = !CGRectIsNull(platter) ? background.layer.cornerRadius : 0;
	if (fabs(state.clipView.layer.cornerRadius - radius) > 0.01) state.clipView.layer.cornerRadius = radius;
	NSString *curve = background.layer.cornerCurve;
	if (curve && ![state.clipView.layer.cornerCurve isEqualToString:curve]) state.clipView.layer.cornerCurve = curve;

	JRFEnsureVisibleColumns(list, slots);
	[state refreshPagesAnimated:NO];
	JRFLayoutPageControl(state);

	if (configChanged || framesChanged || needsMeasure) {
		state.needsLayoutCheck = YES;
		(void)[list layoutMetrics]; // puts the stock values into SpringBoard's cached metrics
		[list layoutIconsNow];
		if (needsMeasure || configChanged) {
			JRFDiagSet(@"frames", [NSString stringWithFormat:@"host %@, stock list %@, platter %@, clip %@, pager %@, list %@",
				NSStringFromClass([host class]), NSStringFromCGRect(stock), NSStringFromCGRect(platter),
				NSStringFromCGRect(clipFrame), NSStringFromCGRect(scrollFrame), NSStringFromCGRect(listFrame)]);
			JRFDiagEvent(@"Dock laid out: %lu pages x %lu apps, page %.1f pt", (unsigned long)pages, (unsigned long)perPage, pageLength);
			static BOOL wroteFirstLayout = NO;
			if (!wroteFirstLayout) {
				wroteFirstLayout = YES;
				JRFDiagWrite(); // right away, so the report has it whatever happens next
			}
		}
	}
}

// > 0 while SBDockView's own -layoutSubviews runs (SpringBoard's part, then the tweak's).
static NSInteger gDockLayoutDepth = 0;

static void JRFLayoutDock(UIView *dock) {
	if (!JRFActive()) return;
	SBIconListView *list = JRFListViewForDock(dock);
	if (!list) return;
	JRFDockState *state = JRFStateForDock(dock, YES);
	if (state.inLayout) return;
	state.inLayout = YES;
	JRFLayoutDockInner(dock, list, state);
	state.inLayout = NO;
}

// Asks for a dock layout on a later run loop turn, at most one at a time. Never from inside a layout pass:
// a layout that asks for another layout of the same view (or one above it) is how SpringBoard got stuck
// laying out the dock forever in 0.3.0.
static void JRFRequestDockLayout(JRFDockState *state) {
	if (!state || state.relayoutPending || !JRFActive()) return;
	state.relayoutPending = YES;
	__weak JRFDockState *weakState = state;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		JRFDockState *strongState = weakState;
		if (!strongState) return;
		strongState.relayoutPending = NO;
		if (JRFActive()) [strongState.dockView setNeedsLayout];
	});
}

// After the tweak switches itself off: the list goes back where SpringBoard had it, at SpringBoard's frame,
// and the dock grid goes back to stock.
static void JRFRestoreStockDock(JRFDockState *state) {
	[state cancelEdgePaging];
	SBIconListView *list = state.listView;
	UIView *host = state.hostView;
	if (list && host && list.superview == state.scrollView) {
		if (state.clipView.superview == host) [host insertSubview:list belowSubview:state.clipView];
		else [host addSubview:list];
		if (state.hasStockFrame) list.frame = state.stockListFrame;
	}
	[state.clipView removeFromSuperview];
	[state.pageControl removeFromSuperview];
	state.geometryValid = NO;
	if (list) JRFSetCachedMetrics(list, nil);
	[state.dockView setNeedsLayout];
}

static void JRFRestoreStockDocks(void) {
	for (SBIconListGridLayoutConfiguration *config in gPatchedConfigs.allObjects) {
		JRFStockGrid *stock = objc_getAssociatedObject(config, JRFStockGridKey);
		if (!stock) continue;
		if (config.numberOfPortraitColumns != stock.portraitColumns) config.numberOfPortraitColumns = stock.portraitColumns;
		if (config.numberOfPortraitRows != stock.portraitRows) config.numberOfPortraitRows = stock.portraitRows;
		if (config.numberOfLandscapeColumns != stock.landscapeColumns) config.numberOfLandscapeColumns = stock.landscapeColumns;
		if (config.numberOfLandscapeRows != stock.landscapeRows) config.numberOfLandscapeRows = stock.landscapeRows;
	}
	for (JRFDockState *state in gDockStates.allObjects) JRFRestoreStockDock(state);
}

// How many apps' worth of positions a page uses. The first page is the stock dock, which centres fewer
// apps; later pages fill from the left, like Home Screen pages, so their apps sit under the first columns.
static NSUInteger JRFPageLayoutCount(JRFDockState *state, NSUInteger page, NSUInteger appsOnPage) {
	NSUInteger perPage = MAX(state.iconsPerPage, (NSUInteger)1);
	return page == 0 ? MIN(MAX(appsOnPage, (NSUInteger)1), perPage) : perPage;
}

// Where an app goes on its page (see JRFPageLayoutCount), moved onto that page.
static CGPoint JRFSlotOrigin(JRFDockState *state, NSUInteger count, NSUInteger index) {
	NSUInteger perPage = MAX(state.iconsPerPage, (NSUInteger)1);
	NSUInteger page = index / perPage;
	NSUInteger slot = index % perPage;
	NSUInteger first = page * perPage;
	NSUInteger onPage = count > first ? MIN(perPage, count - first) : 0;
	NSUInteger apps = JRFPageLayoutCount(state, page, MAX(onPage, slot + 1)); // a slot being dragged into counts too
	return JRFShiftAlong(state->_slotOrigins[apps][slot], state.horizontal, page * state.pageLength);
}

// For a point along the list, the slot it falls in, measured against the apps shown on that page.
static void JRFSlotAtPosition(JRFDockState *state, NSUInteger count, CGFloat position, NSUInteger *outIndex, double *outFraction) {
	NSUInteger perPage = MAX(state.iconsPerPage, (NSUInteger)1);
	BOOL horizontal = state.horizontal;
	NSInteger page = (NSInteger)floor((position - state.pageZero) / state.pageLength);
	page = MAX(0, MIN(page, (NSInteger)state.maxPages - 1));
	NSUInteger first = (NSUInteger)page * perPage;
	NSUInteger onPage = count > first ? MIN(perPage, count - first) : 0;
	if (onPage == 0) {
		*outIndex = first;
		if (outFraction) *outFraction = 0.0;
		return;
	}
	CGFloat shift = page * state.pageLength;
	CGFloat half = state.iconLength / 2.0;
	CGFloat pitch = state.pitch;
	NSUInteger layout = JRFPageLayoutCount(state, (NSUInteger)page, onPage);
	for (NSUInteger i = 0; i < onPage; i++) {
		CGFloat center = JRFMainOf(state->_slotOrigins[layout][i], horizontal) + shift + half;
		BOOL last = (i + 1 == onPage);
		CGFloat boundary = last ? CGFLOAT_MAX : (center + JRFMainOf(state->_slotOrigins[layout][i + 1], horizontal) + shift + half) / 2.0;
		if (last || position < boundary) {
			*outIndex = first + i;
			// Like SpringBoard: the fraction runs across one slot-sized cell centred on the app.
			if (outFraction) *outFraction = MIN(MAX((position - (center - pitch / 2.0)) / pitch, 0.0), 1.0);
			return;
		}
	}
	*outIndex = first + onPage - 1;
	if (outFraction) *outFraction = 1.0;
}

// Safety net: if SpringBoard placed the apps without asking us (a layout path the tweak doesn't know),
// put any app that isn't on its page's spot back there.
static void JRFCorrectIconPositions(JRFDockState *state, SBIconListView *list) {
	if (!state.geometryValid) return;
	NSArray *icons = [[list model] icons];
	NSUInteger count = icons.count, slots = state.iconsPerPage * state.maxPages, moved = 0;
	for (UIView *view in JRFIconViews(list)) {
		NSUInteger index = [icons indexOfObjectIdenticalTo:[(SBIconView *)view icon]];
		if (index == NSNotFound || index >= slots) continue;
		CGPoint origin = JRFSlotOrigin(state, count, index);
		CGSize size = view.bounds.size;
		CGPoint center = CGPointMake(origin.x + size.width / 2.0, origin.y + size.height / 2.0);
		if (fabs(view.center.x - center.x) > 0.5 || fabs(view.center.y - center.y) > 0.5) {
			view.center = center;
			moved++;
		}
	}
	if (moved) {
		if (state.correctedApps == 0) {
			JRFDiagEvent(@"SpringBoard placed %lu dock app(s) without asking the tweak; moved them to their pages", (unsigned long)moved);
		}
		state.correctedApps += moved;
		JRFDiagSet(@"apps moved back into place", [NSString stringWithFormat:@"%lu", (unsigned long)state.correctedApps]);
	}
}

// After SpringBoard lays the apps out: measure the app bottom for the page dots and record the result.
static void JRFCheckIconLayout(JRFDockState *state, SBIconListView *list) {
	if (!state.needsLayoutCheck || !state.geometryValid) return;
	NSArray *icons = [[list model] icons];
	if (icons.count == 0) return;
	UIView *first = nil;
	for (UIView *view in JRFIconViews(list)) {
		if ([(SBIconView *)view icon] == icons[0]) {
			first = view;
			break;
		}
	}
	if (!first) return;
	state.needsLayoutCheck = NO;
	if (state.dockView) state.iconBottom = CGRectGetMaxY([list convertRect:first.frame toView:state.dockView]);

	NSMutableArray *placed = [NSMutableArray array];
	for (UIView *view in JRFIconViews(list)) {
		NSUInteger index = [icons indexOfObjectIdenticalTo:[(SBIconView *)view icon]];
		if (index == NSNotFound) continue;
		CGRect frame = view.frame;
		[placed addObject:[NSString stringWithFormat:@"#%lu at %.1f,%.1f", (unsigned long)index, frame.origin.x, frame.origin.y]];
		if (placed.count >= 8) break;
	}
	JRFDiagSet(@"app frames after layout", [placed componentsJoinedByString:@"; "]);
	JRFDiagSet(@"SpringBoard asked the tweak for positions", [NSString stringWithFormat:@"%lu time(s)", (unsigned long)state.originHits]);
	JRFLayoutPageControl(state);
}

#pragma mark - Flip pages while dragging an app (like folders)

static void JRFDragMoved(id<UIDropSession> session) {
	for (JRFDockState *state in gDockStates) {
		// A drag means jiggle mode: make sure the spare empty page is there.
		CFTimeInterval now = CACurrentMediaTime();
		if (state.geometryValid && !state.forSnapshot && now - state.lastPageRefresh > 0.25) {
			state.lastPageRefresh = now;
			[state refreshPagesAnimated:YES];
		}
		if (!gFlipWhileDragging || !state.geometryValid || state.forSnapshot || state.pagesShown < 2 || !state.clipView.window) {
			if (state.edgeDirection) [state cancelEdgePaging];
			continue;
		}
		CGPoint point = [session locationInView:state.clipView];
		if (!CGRectContainsPoint(state.clipView.bounds, point)) {
			if (state.edgeDirection) [state cancelEdgePaging];
			continue;
		}
		state.lastDragUpdate = now;
		// The edges of the page on screen (the dock background can reach past the screen's edges).
		CGRect page = state.scrollView.frame;
		CGFloat length = state.horizontal ? page.size.width : page.size.height;
		CGFloat position = state.horizontal ? point.x - page.origin.x : point.y - page.origin.y;
		CGFloat zone = MIN((CGFloat)34.0, length * 0.12);
		NSInteger direction = position < zone ? -1 : (position > length - zone ? 1 : 0);
		[state updateEdgeDirection:direction];
	}
}

static void JRFDragLeft(SBIconListView *list, BOOL ended) {
	JRFDockState *state = JRFStateForListView(list);
	if (!state) return;
	[state cancelEdgePaging];
	if (!ended) return;
	// The drop may have emptied or filled a page.
	__weak JRFDockState *weakState = state;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (JRFActive()) [weakState refreshPagesAnimated:YES];
	});
}

#pragma mark - Back to page 1 (Home button, opening an app)

static void JRFReturnDocksToFirstPage(BOOL animated) {
	for (JRFDockState *state in gDockStates.allObjects) {
		if (!state.geometryValid || fabs([state mainOffset]) < 0.5) continue;
		UIScrollView *scroll = state.scrollView;
		if (scroll.tracking || scroll.dragging) continue; // a finger is on the dock
		[state cancelEdgePaging];
		[state setMainOffset:0 animated:animated && !state.forSnapshot && state.clipView.window != nil];
	}
}

static BOOL gHomeResetPending = NO;

// The Home button takes the Home Screen back to its first page; with the setting on, the dock goes too.
static void JRFHomeButtonPressed(void) {
	if (!gHomeResetsDock || !JRFActive() || gHomeResetPending) return;
	gHomeResetPending = YES;
	dispatch_async(dispatch_get_main_queue(), ^{ // after SpringBoard has handled the press
		gHomeResetPending = NO;
		if (gHomeResetsDock && JRFActive()) JRFReturnDocksToFirstPage(YES);
	});
}

static NSUInteger gFrontChanges = 0; // counts changes of what's in front (an app, or the Home Screen)
static BOOL gAppInFront = NO;

// An app opened. Once its opening animation is over (so the dock isn't seen moving, and the animation
// started from the right icon), take the dock back to page 1 if it's still in front.
static void JRFAppOpened(void) {
	if (!gAppOpenResetsDock || !JRFActive()) return;
	NSUInteger change = gFrontChanges;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (!gAppOpenResetsDock || !JRFActive() || change != gFrontChanges || !gAppInFront) return;
		JRFReturnDocksToFirstPage(NO);
	});
}

// What's in front changed: an app (opened from anywhere) or the Home Screen (nil).
static void JRFFrontDisplayChanged(id display) {
	gFrontChanges++;
	Class applicationClass = objc_getClass("SBApplication");
	gAppInFront = applicationClass && [display isKindOfClass:applicationClass];
	if (gAppInFront) JRFAppOpened();
}

// Fallback when SpringBoard can't report what's in front: an app was opened from its icon.
static void JRFIconLaunched(void) {
	gFrontChanges++;
	gAppInFront = YES;
	JRFAppOpened();
}

#pragma mark - Dock backup (puts extra dock apps back after an unjailbroken boot)

static NSArray *gLastSavedDock;

static NSArray *JRFReadDockBackup(void) {
	NSData *data = [NSData dataWithContentsOfFile:JRFDockBackupPath];
	if (!data) return nil;
	id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
	id dock = [plist isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)plist)[@"dock"] : nil;
	return [dock isKindOfClass:[NSArray class]] ? dock : nil;
}

static void JRFBackUpDock(NSArray *dock) {
	@synchronized ([JRFStockGrid class]) {
		if ([dock isEqualToArray:gLastSavedDock]) return;
		NSDictionary *plist = @{ @"dock": dock, @"pages": @(gPages), @"date": [NSDate date] };
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
		if (data && [data writeToFile:JRFDockBackupPath atomically:YES]) gLastSavedDock = [dock copy];
	}
}

// SpringBoard keeps the first dock apps and moves the rest out when it boots without the tweak. If the dock
// on disk is exactly a full stock dock taken from our last backup, put the rest back and take those apps off
// the Home Screen pages they were moved to.
static NSDictionary *JRFRestoreEvictedDockIcons(NSDictionary *state) {
	NSArray *disk = state[JRFIconStateDockKey];
	NSArray *backup = JRFReadDockBackup();
	NSUInteger perPage = JRFIconsPerPage();
	if (![disk isKindOfClass:[NSArray class]] || disk.count != perPage || backup.count <= perPage) return nil;
	for (id item in disk) {
		if (![backup containsObject:item]) return nil; // the dock changed some other way; leave it alone
	}

	NSArray *restored = backup.count > JRFDockCapacity() ? [backup subarrayWithRange:NSMakeRange(0, JRFDockCapacity())] : backup;
	for (id item in disk) {
		if (![restored containsObject:item]) return nil; // fewer pages than before; don't drop anything
	}
	NSMutableArray *evicted = [NSMutableArray array];
	for (id item in restored) {
		if (![disk containsObject:item]) [evicted addObject:item];
	}
	if (evicted.count == 0) return nil;

	NSMutableDictionary *newState = [state mutableCopy];
	newState[JRFIconStateDockKey] = restored;

	NSArray *lists = state[JRFIconStateListsKey];
	if ([lists isKindOfClass:[NSArray class]]) {
		NSMutableArray *remaining = [evicted mutableCopy];
		NSMutableArray *newLists = [NSMutableArray arrayWithCapacity:lists.count];
		for (id page in lists) {
			if (![page isKindOfClass:[NSArray class]]) {
				[newLists addObject:page];
				continue;
			}
			NSMutableArray *newPage = [NSMutableArray arrayWithCapacity:[(NSArray *)page count]];
			for (id item in (NSArray *)page) {
				NSUInteger index = [remaining indexOfObject:item];
				if (index != NSNotFound) [remaining removeObjectAtIndex:index];
				else [newPage addObject:item];
			}
			[newLists addObject:newPage];
		}
		newState[JRFIconStateListsKey] = newLists;
	}

	JRFLog(@"Put %lu dock app(s) back that SpringBoard moved out while the tweak wasn't loaded", (unsigned long)evicted.count);
	return newState;
}

#pragma mark - Hooks (all through Substrate)

static CGPoint JRFPlacedOrigin(SBIconListView *list, JRFIconCoordinate coordinate, NSUInteger count, CGPoint original) {
	JRFDockState *state = JRFStateForListView(list);
	if (!state.geometryValid || JRFStockQueryActive() || !JRFActive()) return original;
	NSInteger index = JRFIndexForCoordinate(coordinate);
	if (index < 0 || (NSUInteger)index >= state.iconsPerPage * state.maxPages) return original;
	state.originHits++;
	return JRFSlotOrigin(state, count, (NSUInteger)index);
}

%hook SBHDefaultIconListLayoutProvider

- (id)layoutForIconLocation:(NSString *)iconLocation {
	id layout = %orig;
	if ([iconLocation isKindOfClass:[NSString class]] && [iconLocation isEqualToString:JRFDockIconLocation] &&
	    [layout respondsToSelector:@selector(layoutConfiguration)]) {
		JRFPatchDockConfiguration([layout layoutConfiguration]);
	}
	return layout;
}

%end

%hook SBIconListGridLayoutConfiguration

// While SpringBoard is asked about a stock dock, the dock configuration reports its stock grid.
- (NSUInteger)numberOfPortraitColumns {
	NSUInteger value = %orig;
	if (JRFStockQueryActive()) {
		JRFStockGrid *stock = objc_getAssociatedObject(self, JRFStockGridKey);
		if (stock) return stock.portraitColumns;
	}
	return value;
}

- (NSUInteger)numberOfPortraitRows {
	NSUInteger value = %orig;
	if (JRFStockQueryActive()) {
		JRFStockGrid *stock = objc_getAssociatedObject(self, JRFStockGridKey);
		if (stock) return stock.portraitRows;
	}
	return value;
}

- (NSUInteger)numberOfLandscapeColumns {
	NSUInteger value = %orig;
	if (JRFStockQueryActive()) {
		JRFStockGrid *stock = objc_getAssociatedObject(self, JRFStockGridKey);
		if (stock) return stock.landscapeColumns;
	}
	return value;
}

- (NSUInteger)numberOfLandscapeRows {
	NSUInteger value = %orig;
	if (JRFStockQueryActive()) {
		JRFStockGrid *stock = objc_getAssociatedObject(self, JRFStockGridKey);
		if (stock) return stock.landscapeRows;
	}
	return value;
}

- (id)copyWithZone:(NSZone *)zone {
	id copy = %orig;
	id stock = objc_getAssociatedObject(self, JRFStockGridKey);
	if (stock && copy && copy != self) objc_setAssociatedObject(copy, JRFStockGridKey, stock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return copy;
}

%end

%hook SBIconController

- (NSUInteger)maxIconCountForDock {
	NSUInteger count = %orig;
	if (JRFStockQueryActive() || !JRFActive()) return count;
	return count ? MAX(count, JRFDockCapacity()) : count;
}

%end

%hook SBIconListModel

- (JRFGridSize)gridSize {
	JRFGridSize size = %orig;
	if (!JRFActive()) return size;
	if (JRFStockQueryActive()) {
		return (gStockDockModelGrid.columns && JRFIsDockModel(self)) ? gStockDockModelGrid : size;
	}
	NSUInteger capacity = JRFDockCapacity();
	if ((NSUInteger)size.columns * size.rows < capacity && JRFIsDockModel(self)) {
		if (size.rows <= 1) {
			size.columns = (uint16_t)capacity;
			size.rows = 1;
		} else if (size.columns <= 1) {
			size.rows = (uint16_t)capacity;
		}
	}
	return size;
}

- (NSUInteger)maxNumberOfIcons {
	NSUInteger count = %orig;
	if (!JRFActive()) return count;
	if (JRFStockQueryActive()) {
		if (gStockDockModelGrid.columns && JRFIsDockModel(self)) return (NSUInteger)gStockDockModelGrid.columns * MAX((NSUInteger)gStockDockModelGrid.rows, (NSUInteger)1);
		return count;
	}
	NSUInteger capacity = JRFDockCapacity();
	if (count && count < capacity && JRFIsDockModel(self)) return capacity;
	return count;
}

%end

%hook SBDockIconListView

- (BOOL)allowsAddingIconCount:(NSUInteger)count {
	if (%orig) return YES;
	if (!JRFActive()) return NO;
	// Up to 4 apps per page, on as many pages as are set up.
	return JRFIconCount(self) + count <= JRFDockCapacity();
}

- (id)layoutMetrics {
	id metrics = %orig;
	JRFDockState *state = JRFStateForListView(self);
	if (state && JRFActive()) JRFPatchDockMetrics(metrics, state);
	return metrics;
}

- (BOOL)automaticallyAdjustsLayoutMetricsToFit {
	// Fitting would squeeze the long row of slots into one page.
	if (!JRFActive() || JRFStockQueryActive()) return %orig;
	return NO;
}

- (CGSize)iconSpacing {
	CGSize spacing = %orig;
	JRFDockState *state = JRFStateForListView(self);
	if (state.geometryValid && !JRFStockQueryActive() && JRFActive()) {
		CGFloat gap = MAX((CGFloat)0, state.pitch - state.iconLength);
		if (state.horizontal) spacing.width = gap;
		else spacing.height = gap;
	}
	return spacing;
}

- (CGSize)effectiveIconSpacing {
	CGSize spacing = %orig;
	JRFDockState *state = JRFStateForListView(self);
	if (state.geometryValid && !JRFStockQueryActive() && JRFActive()) {
		CGFloat gap = MAX((CGFloat)0, state.pitch - state.iconLength);
		if (state.horizontal) spacing.width = gap;
		else spacing.height = gap;
	}
	return spacing;
}

- (void)layoutIconsNow {
	JRFDockState *state = JRFStateForListView(self);
	if (!state || !JRFActive()) {
		%orig;
		return;
	}
	static JRFRate rate;
	if (JRFRateExceeded(&rate, JRFMaxIconLayoutsPerSecond, 1.0)) {
		JRFTrip(@"the dock's apps kept being laid out again and again (a layout loop)",
			[NSString stringWithFormat:@"More than %d dock app layouts in one second.", JRFMaxIconLayoutsPerSecond]);
		%orig;
		return;
	}
	NSUInteger hitsBefore = state.originHits;
	%orig;
	if (JRFStockQueryActive() || !JRFActive()) return;
	if (self.superview != state.scrollView || !JRFRectsClose(self.frame, state.appliedListFrame)) {
		// The list isn't at the tweak's frame. Inside the dock's own layout that is expected (SpringBoard sizes
		// it for one page, then the tweak resizes it), so do nothing. Otherwise lay the dock out again, later.
		if (gDockLayoutDepth == 0) JRFRequestDockLayout(state);
		return;
	}
	if (state.originHits == hitsBefore) JRFCorrectIconPositions(state, self);
	[state refreshPagesAnimated:YES];
	JRFCheckIconLayout(state, self);
}

- (void)setEditing:(BOOL)editing {
	%orig;
	JRFDockState *state = JRFStateForListView(self);
	if (!state || !JRFActive()) return;
	if (!editing) [state cancelEdgePaging];
	[state refreshPagesEditing:editing animated:YES];
	// Once SpringBoard has finished switching jiggle mode on or off, look again (an empty spare page goes away).
	__weak JRFDockState *weakState = state;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (JRFActive()) [weakState refreshPagesAnimated:YES];
	});
}

%end

%hook SBDockView

- (void)layoutSubviews {
	if (!JRFActive()) {
		%orig;
		return;
	}
	static JRFRate rate;
	if (JRFRateExceeded(&rate, JRFMaxDockLayoutsPerSecond, 1.0)) {
		JRFTrip(@"the dock kept being laid out again and again (a layout loop)",
			[NSString stringWithFormat:@"More than %d dock layouts in one second.", JRFMaxDockLayoutsPerSecond]);
		%orig;
		return;
	}
	gDockLayoutDepth++;
	%orig;
	JRFLayoutDock(self);
	gDockLayoutDepth--;
}

%end

%hook SBDefaultIconModelStore

- (id)loadCurrentIconState:(NSError **)error {
	id state = %orig;
	if (gRestoreDock && JRFActive() && [state isKindOfClass:[NSDictionary class]]) {
		NSDictionary *restored = JRFRestoreEvictedDockIcons(state);
		if (restored) return restored;
	}
	return state;
}

- (BOOL)saveCurrentIconState:(id)state error:(NSError **)error {
	BOOL saved = %orig;
	// Only once the paged dock is running, so a dock cut short by a problem never replaces the backup.
	if (saved && gRestoreDock && gDockOperating && JRFActive() && [state isKindOfClass:[NSDictionary class]]) {
		id dock = ((NSDictionary *)state)[JRFIconStateDockKey];
		if ([dock isKindOfClass:[NSArray class]]) JRFBackUpDock(dock);
	}
	return saved;
}

%end

// The hooks below are installed only when this iOS version has the method (checked in %ctor).

// iOS 16: the dock's own placement method, which spreads the apps by how many there are.
%group DockOriginForCount
%hook SBDockIconListView
- (CGPoint)originForIconAtCoordinate:(JRFIconCoordinate)coordinate numberOfIcons:(NSUInteger)numberOfIcons {
	CGPoint origin = %orig;
	return JRFPlacedOrigin(self, coordinate, numberOfIcons ?: JRFIconCount(self), origin);
}
%end
%end

// The generic icon list placement method.
%group DockOriginForMetrics
%hook SBDockIconListView
- (CGPoint)originForIconAtCoordinate:(JRFIconCoordinate)coordinate metrics:(id)metrics {
	CGPoint origin = %orig;
	return JRFPlacedOrigin(self, coordinate, JRFIconCount(self), origin);
}
%end
%end

%group DockMetricsForOrientation
%hook SBDockIconListView
- (id)layoutMetricsForOrientation:(NSInteger)orientation {
	id metrics = %orig;
	JRFDockState *state = JRFStateForListView(self);
	if (state && JRFActive() && orientation == JRFListOrientation(self)) JRFPatchDockMetrics(metrics, state);
	return metrics;
}
%end
%end

// Point to slot: drops land on the spot shown under the finger, on every page.
%group DockColumnAtPoint
%hook SBDockIconListView
- (NSUInteger)columnAtPoint:(CGPoint)point metrics:(id)metrics fractionOfDistanceThroughColumn:(double *)fraction {
	JRFDockState *state = JRFStateForListView(self);
	if (!state.geometryValid || !state.horizontal || !gColumnAtPointBaseKnown || JRFStockQueryActive() || !JRFActive()) return %orig;
	NSUInteger index = 0;
	double value = 0;
	JRFSlotAtPosition(state, JRFIconCount(self), point.x, &index, &value);
	if (fraction) *fraction = value;
	return (NSUInteger)gColumnAtPointBase + index;
}
%end
%end

%group DockRowAtPoint
%hook SBDockIconListView
- (NSUInteger)rowAtPoint:(CGPoint)point metrics:(id)metrics {
	JRFDockState *state = JRFStateForListView(self);
	if (!state.geometryValid || state.horizontal || !gRowAtPointBaseKnown || JRFStockQueryActive() || !JRFActive()) return %orig;
	NSUInteger index = 0;
	JRFSlotAtPosition(state, JRFIconCount(self), point.y, &index, NULL);
	return (NSUInteger)gRowAtPointBase + index;
}
%end
%end

%group DockCoordinateAtPoint
%hook SBDockIconListView
- (JRFIconCoordinate)coordinateAtPoint:(CGPoint)point {
	JRFDockState *state = JRFStateForListView(self);
	BOOL canBuildCoordinate = gFieldOrderKnown || [self respondsToSelector:@selector(iconCoordinateForIndex:metrics:)];
	if (!state.geometryValid || !canBuildCoordinate || JRFStockQueryActive() || !JRFActive()) return %orig;
	NSUInteger index = 0;
	JRFSlotAtPosition(state, JRFIconCount(self), JRFMainOf(point, state.horizontal), &index, NULL);
	return JRFCoordinateForIndex(self, [self layoutMetrics], index, state.horizontal);
}
%end
%end

// Capacity checks that exist on some iOS versions only.
%group DockMaxIcons
%hook SBDockIconListView
+ (NSUInteger)maxIcons {
	NSUInteger value = %orig;
	if (JRFStockQueryActive() || !JRFActive()) return value;
	return MAX(value, JRFDockCapacity());
}
%end
%end

%group ModelIsFull
%hook SBIconListModel
- (BOOL)isFull {
	BOOL full = %orig;
	if (!full || JRFStockQueryActive() || !JRFActive() || !JRFIsDockModel(self)) return full;
	return [[self icons] count] >= JRFDockCapacity();
}
%end
%end

// Finds the dock's list model as soon as SpringBoard asks the root folder for it (before apps load).
%group RootFolderDock
%hook JRFRootFolderStandIn
- (id)dock {
	id dock = %orig;
	if (dock) JRFNoteDockModel(dock);
	return dock;
}
%end
%end

// Icon drags: SpringBoard's drop handler for each icon list reports where the dragged app is.
%group DragWatcher
%hook SBIconListViewDraggingDestinationDelegate

- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction sessionDidUpdate:(id<UIDropSession>)session {
	UIDropProposal *proposal = %orig;
	if (JRFActive()) JRFDragMoved(session);
	return proposal;
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidExit:(id<UIDropSession>)session {
	%orig;
	if (JRFActive() && [self respondsToSelector:@selector(iconListView)]) JRFDragLeft([self iconListView], NO);
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidEnd:(id<UIDropSession>)session {
	%orig;
	if (JRFActive() && [self respondsToSelector:@selector(iconListView)]) JRFDragLeft([self iconListView], YES);
}

%end
%end

// Home button presses (iPhones with a Home button). Each is installed only if this iOS version has it.
%group HomePressUp
%hook SBHomeHardwareButtonActions
- (void)performSinglePressUpActions {
	%orig;
	JRFHomeButtonPressed();
}
%end
%end

%group HomePressUpWithSource
%hook SBHomeHardwareButtonActions
- (void)performSinglePressUpActionsWithSourceType:(unsigned long long)sourceType {
	%orig;
	JRFHomeButtonPressed();
}
%end
%end

// Opening an app (from anywhere): SpringBoard reports the new app in front.
%group FrontDisplay
%hook SpringBoard
- (void)frontDisplayDidChange:(id)display {
	%orig;
	JRFFrontDisplayChanged(display);
}
%end
%end

// Fallback: an app opened from its icon.
%group IconLaunch
%hook SBHIconManager
- (void)launchFromIconView:(id)iconView withActions:(id)actions {
	%orig;
	JRFIconLaunched();
}
%end
%end

%group HomePressUIController
%hook SBUIController
- (BOOL)handleHomeButtonSinglePressUpWithSourceType:(unsigned long long)sourceType {
	BOOL handled = %orig;
	JRFHomeButtonPressed();
	return handled;
}
%end
%end

#pragma mark - Setup

static void JRFPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	dispatch_async(dispatch_get_main_queue(), ^{
		JRFLoadLivePrefs();
		if (!JRFActive()) return;
		for (JRFDockState *state in gDockStates.allObjects) {
			if (!gFlipWhileDragging) [state cancelEdgePaging];
			[state refreshPagesAnimated:YES];
			JRFLayoutPageControl(state);
			[state.dockView setNeedsLayout];
		}
	});
}

static BOOL JRFHasMethod(Class cls, SEL selector) {
	return cls && class_getInstanceMethod(cls, selector) != NULL;
}

#pragma mark - Freeze watchdog

// The main run loop reports each step; a thread of the tweak's own checks every second that steps keep coming.
static _Atomic(double) gMainBeat = 0;  // when the main thread last finished a step (0: watchdog not started)
static atomic_bool gMainIdle;          // the main run loop is asleep, waiting for something to do
static atomic_bool gRunLoopStarted;    // the main run loop has reported at least one step
static mach_port_t gMainThreadPort = MACH_PORT_NULL;
static pthread_t gMainPthread;
static dispatch_source_t gWatchdogTimer;
static double gFreezeBeat = 0;          // watchdog queue only: the step the current freeze started after
static BOOL gFreezeReported = NO;       // watchdog queue only

static uintptr_t JRFStripCode(uintptr_t value) {
#if __has_feature(ptrauth_calls)
	return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_asia);
#else
	return value;
#endif
}

static uintptr_t JRFStripData(uintptr_t value) {
#if __has_feature(ptrauth_calls)
	return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_asda);
#else
	return value;
#endif
}

// Return addresses on the main thread's stack, read while it is paused for a moment. Nothing allocates
// memory or takes a lock while it is paused (it could be holding that lock).
static int JRFCaptureMainThread(uintptr_t *frames, int maxFrames) {
	if (gMainThreadPort == MACH_PORT_NULL || maxFrames < 2) return 0;
	uintptr_t stackTop = (uintptr_t)pthread_get_stackaddr_np(gMainPthread);
	uintptr_t stackBottom = stackTop - (uintptr_t)pthread_get_stacksize_np(gMainPthread);
	if (thread_suspend(gMainThreadPort) != KERN_SUCCESS) return 0;
	int count = 0;
	arm_thread_state64_t state;
	mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
	if (thread_get_state(gMainThreadPort, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
		uintptr_t pc = (uintptr_t)state.__opaque_pc, lr = (uintptr_t)state.__opaque_lr, fp = (uintptr_t)state.__opaque_fp;
#else
		uintptr_t pc = (uintptr_t)state.__pc, lr = (uintptr_t)state.__lr, fp = (uintptr_t)state.__fp;
#endif
		frames[count++] = JRFStripCode(pc);
		frames[count++] = JRFStripCode(lr);
		fp = JRFStripData(fp);
		while (count < maxFrames && fp > stackBottom && fp + 2 * sizeof(uintptr_t) <= stackTop && (fp & 0x7) == 0) {
			const uintptr_t *frame = (const uintptr_t *)fp;
			uintptr_t next = JRFStripData(frame[0]);
			uintptr_t ret = JRFStripCode(frame[1]);
			if (!ret) break;
			frames[count++] = ret;
			if (next <= fp) break;
			fp = next;
		}
	}
	thread_resume(gMainThreadPort);
	return count;
}

static NSString *JRFDescribeAddress(uintptr_t address, BOOL isReturnAddress) {
	Dl_info info;
	memset(&info, 0, sizeof(info));
	uintptr_t lookup = (isReturnAddress && address) ? address - 1 : address; // stay inside the calling function
	if (!address || !dladdr((const void *)lookup, &info) || !info.dli_fname) return [NSString stringWithFormat:@"0x%lx", (unsigned long)address];
	NSString *image = [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] ?: @"?";
	unsigned long offset = (unsigned long)(address - (uintptr_t)info.dli_fbase);
	if (info.dli_sname && info.dli_saddr) {
		return [NSString stringWithFormat:@"%@ +0x%lx  %s + %lu", image, offset, info.dli_sname, (unsigned long)(address - (uintptr_t)info.dli_saddr)];
	}
	return [NSString stringWithFormat:@"%@ +0x%lx", image, offset];
}

// A few samples of where the main thread is, a moment apart (a loop moves around, a deadlock doesn't).
static NSString *JRFSampleMainThread(void) {
	NSMutableString *text = [NSMutableString string];
	for (int sample = 1; sample <= 3; sample++) {
		uintptr_t frames[64];
		int count = JRFCaptureMainThread(frames, 64);
		[text appendFormat:@"Main thread, sample %d of 3:\n", sample];
		if (count == 0) [text appendString:@"  (couldn't be read)\n"];
		for (int i = 0; i < count; i++) [text appendFormat:@"  %2d %@\n", i, JRFDescribeAddress(frames[i], i > 0)];
		if (sample < 3) usleep(150 * 1000);
	}
	return text;
}

// This dylib's UUID, load address and architecture, to match addresses in a report to the build.
static NSString *JRFImageDescription(void) {
	Dl_info info;
	memset(&info, 0, sizeof(info));
	if (!dladdr((const void *)&JRFImageDescription, &info) || !info.dli_fbase) return @"unknown";
#if __arm64e__
	NSString *arch = @"arm64e";
#else
	NSString *arch = @"arm64";
#endif
	const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
	const uint8_t *cursor = (const uint8_t *)(header + 1);
	for (uint32_t i = 0; header->magic == MH_MAGIC_64 && i < header->ncmds; i++) {
		const struct load_command *command = (const struct load_command *)cursor;
		if (command->cmd == LC_UUID) {
			NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid];
			return [NSString stringWithFormat:@"%@ %@ at %p", arch, uuid.UUIDString, header];
		}
		cursor += command->cmdsize;
	}
	return [NSString stringWithFormat:@"%@ at %p", arch, header];
}

static void JRFWatchdogTick(void) {
	double beat = atomic_load_explicit(&gMainBeat, memory_order_relaxed);
	if (beat <= 0 || atomic_load_explicit(&gMainIdle, memory_order_relaxed)) return; // not started, or asleep
	// Before the main run loop starts, SpringBoard is still launching (loading the Home Screen layout, among
	// other things), which can legitimately take longer.
	BOOL started = atomic_load_explicit(&gRunLoopStarted, memory_order_relaxed);
	double switchOffAfter = started ? JRFFreezeSwitchOffSeconds : JRFLaunchFreezeSwitchOffSeconds;
	double restartAfter = started ? JRFFreezeRestartSeconds : JRFLaunchFreezeRestartSeconds;
	if (beat != gFreezeBeat) {
		// The main thread has moved on since the last check: any earlier freeze is over.
		gFreezeBeat = beat;
		gFreezeReported = NO;
	}
	double stuck = CACurrentMediaTime() - beat;
	if (stuck >= switchOffAfter && !gFreezeReported) {
		gFreezeReported = YES;
		NSString *reason = [NSString stringWithFormat:@"SpringBoard froze for %.0f seconds while Jax Riffle was running%@", stuck,
			started ? @"" : @" (while SpringBoard was starting up)"];
		// Switch off first (if the freeze comes from the tweak's hooks, this alone can end it), then work out
		// where the main thread is stuck on another thread, so this check keeps running whatever happens there.
		JRFTrip(reason, @"(Working out where SpringBoard was stuck.)");
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			@autoreleasepool {
				NSString *where = JRFSampleMainThread();
				JRFTrip(reason, [NSString stringWithFormat:@"Jax Riffle: %@\n%@", JRFImageDescription(), where]);
			}
		});
	}
	if (stuck >= restartAfter && gFreezeReported) {
		// Still stuck. Restart SpringBoard now rather than leave the phone frozen until the system's watchdog
		// panics at 3 minutes. The tweak stays off on the next launch, so this can't repeat.
		JRFLog(@"SpringBoard has been frozen for %.0f seconds; restarting it", stuck);
		NSString *details = JRFReadSafetyRecord()[@"details"];
		NSString *reason = [NSString stringWithFormat:@"SpringBoard froze for %.0f seconds while Jax Riffle was running, so Jax Riffle restarted SpringBoard", stuck];
		JRFWriteSafetyRecord(reason, details);
		os_unfair_lock_lock(&gDiagLock);
		gDiagSafetyText = [NSString stringWithFormat:@"SWITCHED ITSELF OFF: %@\n%@", reason, details ?: @""];
		os_unfair_lock_unlock(&gDiagLock);
		JRFDiagWrite();
		abort();
	}
}

static void JRFStartFreezeWatchdog(void) {
	if (!pthread_main_np()) return; // needs to know which thread is the main one
	gMainThreadPort = mach_thread_self();
	gMainPthread = pthread_self();
	// Watch from now on, not only once the run loop starts: SpringBoard could get stuck before that.
	atomic_store_explicit(&gMainIdle, false, memory_order_relaxed);
	atomic_store_explicit(&gMainBeat, CACurrentMediaTime(), memory_order_relaxed);

	CFRunLoopRef mainLoop = CFRunLoopGetMain();
	// First to hear about every step of the main run loop: it is busy.
	CFRunLoopObserverRef busy = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
		kCFRunLoopEntry | kCFRunLoopBeforeTimers | kCFRunLoopBeforeSources | kCFRunLoopAfterWaiting | kCFRunLoopExit,
		true, LONG_MIN, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
			atomic_store_explicit(&gRunLoopStarted, true, memory_order_relaxed);
			atomic_store_explicit(&gMainIdle, false, memory_order_relaxed);
			atomic_store_explicit(&gMainBeat, CACurrentMediaTime(), memory_order_relaxed);
		});
	// Last thing before it sleeps (after Core Animation has laid everything out): it is idle.
	CFRunLoopObserverRef idle = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting,
		true, LONG_MAX, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
			atomic_store_explicit(&gMainBeat, CACurrentMediaTime(), memory_order_relaxed);
			atomic_store_explicit(&gMainIdle, true, memory_order_relaxed);
		});
	if (!busy || !idle) return;
	// Common modes, plus UIKit's own modes for launching and for waiting on events, which it can run on
	// their own for a while (being in one of those isn't a freeze).
	CFStringRef modes[] = { kCFRunLoopCommonModes, CFSTR("UIInitializationRunLoopMode"), CFSTR("GSEventReceiveRunLoopMode") };
	for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
		CFRunLoopAddObserver(mainLoop, busy, modes[i]);
		CFRunLoopAddObserver(mainLoop, idle, modes[i]);
	}

	dispatch_queue_t queue = dispatch_queue_create("com.alienjax.riffle.watchdog", DISPATCH_QUEUE_SERIAL);
	gWatchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_source_set_timer(gWatchdogTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
	dispatch_source_set_event_handler(gWatchdogTimer, ^{
		@autoreleasepool {
			JRFWatchdogTick();
		}
	});
	dispatch_resume(gWatchdogTimer);
}

%ctor {
	@autoreleasepool {
		if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPhone) return;

		gLaunchTime = CACurrentMediaTime();
		gDiag = [NSMutableDictionary dictionary];
		gDiagEvents = [NSMutableArray array];
		struct utsname systemInfo;
		uname(&systemInfo);
		NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
		JRFDiagSet(@"device", [NSString stringWithUTF8String:systemInfo.machine]);
		JRFDiagSet(@"iOS", [NSString stringWithFormat:@"%ld.%ld.%ld", (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion]);

		JRFLoadLaunchPrefs();
		JRFLoadLivePrefs();
		JRFDiagSet(@"settings", [NSString stringWithFormat:@"enabled %@, up to %lu pages, dots %@, flip %@, home button %@, app launch %@, restore %@",
			JRFYesNo(gEnabled), (unsigned long)gPages, JRFYesNo(gShowDots), JRFYesNo(gFlipWhileDragging), JRFYesNo(gHomeResetsDock),
			JRFYesNo(gAppOpenResetsDock), JRFYesNo(gRestoreDock)]);
		if (!gEnabled) {
			JRFDiagEvent(@"Disabled in Settings; not loading");
			JRFDiagWrite();
			return;
		}

		// Switched itself off after a problem: stay off until it is turned back on in Settings. A new version
		// gets a fresh start.
		NSDictionary *safety = JRFReadSafetyRecord();
		if ([safety[@"tripped"] respondsToSelector:@selector(boolValue)] && [safety[@"tripped"] boolValue]) {
			// "Turn Back On" in Settings records when it was tapped (and deletes the record if it can).
			NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:JRFPrefsDomain];
			id turnedBackOn = [defaults objectForKey:@"turnedBackOnAt"];
			id trippedAt = safety[@"date"];
			BOOL cleared = [turnedBackOn isKindOfClass:[NSDate class]] && [trippedAt isKindOfClass:[NSDate class]] &&
			               [(NSDate *)turnedBackOn compare:(NSDate *)trippedAt] != NSOrderedAscending;
			if (cleared) {
				[[NSFileManager defaultManager] removeItemAtPath:JRFSafetyPath error:NULL];
				JRFDiagEvent(@"Turned back on in Settings after: %@", safety[@"reason"]);
			} else if ([safety[@"version"] isEqual:JRFVersion]) {
				os_unfair_lock_lock(&gDiagLock);
				gDiagSafetyText = [NSString stringWithFormat:@"SWITCHED OFF since %@: %@\n%@", safety[@"date"], safety[@"reason"], safety[@"details"] ?: @""];
				os_unfair_lock_unlock(&gDiagLock);
				JRFDiagEvent(@"Switched off after a problem (top of this report); not loading. Settings → Jax Riffle → Turn Back On.");
				JRFDiagWrite();
				return;
			} else {
				[[NSFileManager defaultManager] removeItemAtPath:JRFSafetyPath error:NULL];
				JRFDiagEvent(@"Cleared the switch-off left by version %@ (%@)", safety[@"version"], safety[@"reason"]);
			}
		}

		static const char *const required[] = {
			"SBDockView", "SBDockIconListView", "SBIconListView", "SBIconListModel", "SBIconListGridLayoutConfiguration",
			"SBHDefaultIconListLayoutProvider", "SBIconController", "SBDefaultIconModelStore",
		};
		for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); i++) {
			if (!objc_getClass(required[i])) {
				JRFDiagEvent(@"%s not found on this iOS version; not loading", required[i]);
				JRFDiagWrite();
				return;
			}
		}

		// Atria: iOS 16 swapped SBIconCoordinate's fields. Confirmed at runtime when the dock is measured.
		gColumnIsFirstField = version.majorVersion >= 16;

		gDockListViewClass = objc_getClass("SBDockIconListView");
		gIconViewClass = objc_getClass("SBIconView");
		gMetricsClass = objc_getClass("SBIconListViewLayoutMetrics");
		gDockStates = [NSHashTable weakObjectsHashTable];
		gPatchedConfigs = [NSHashTable weakObjectsHashTable];
		gLastSavedDock = JRFReadDockBackup();

		%init;

		Class dockList = gDockListViewClass;
		Class model = objc_getClass("SBIconListModel");
		NSMutableArray *installed = [NSMutableArray array];
		if (JRFHasMethod(dockList, @selector(originForIconAtCoordinate:numberOfIcons:))) { %init(DockOriginForCount); [installed addObject:@"dock placement (numberOfIcons)"]; }
		if (JRFHasMethod(dockList, @selector(originForIconAtCoordinate:metrics:))) { %init(DockOriginForMetrics); [installed addObject:@"list placement (metrics)"]; }
		if (JRFHasMethod(dockList, @selector(layoutMetricsForOrientation:))) { %init(DockMetricsForOrientation); [installed addObject:@"metrics for orientation"]; }
		if (JRFHasMethod(dockList, @selector(columnAtPoint:metrics:fractionOfDistanceThroughColumn:))) { %init(DockColumnAtPoint); [installed addObject:@"column at point"]; }
		if (JRFHasMethod(dockList, @selector(rowAtPoint:metrics:))) { %init(DockRowAtPoint); [installed addObject:@"row at point"]; }
		if (JRFHasMethod(dockList, @selector(coordinateAtPoint:))) { %init(DockCoordinateAtPoint); [installed addObject:@"coordinate at point"]; }
		if (dockList && class_getClassMethod(dockList, @selector(maxIcons))) { %init(DockMaxIcons); [installed addObject:@"maxIcons"]; }
		if (JRFHasMethod(model, @selector(isFull))) { %init(ModelIsFull); [installed addObject:@"isFull"]; }
		Class rootFolder = objc_getClass("SBRootFolderWithDock");
		if (!JRFHasMethod(rootFolder, @selector(dock))) rootFolder = objc_getClass("SBRootFolder");
		if (JRFHasMethod(rootFolder, @selector(dock))) {
			%init(RootFolderDock, JRFRootFolderStandIn = rootFolder);
			[installed addObject:[NSString stringWithFormat:@"%@ dock", NSStringFromClass(rootFolder)]];
		}
		Class dropDelegate = objc_getClass("SBIconListViewDraggingDestinationDelegate");
		if (JRFHasMethod(dropDelegate, @selector(dropInteraction:sessionDidUpdate:))) { %init(DragWatcher); [installed addObject:@"drag watcher"]; }
		Class buttonActions = objc_getClass("SBHomeHardwareButtonActions");
		BOOL homePlain = JRFHasMethod(buttonActions, @selector(performSinglePressUpActions));
		BOOL homeSource = JRFHasMethod(buttonActions, @selector(performSinglePressUpActionsWithSourceType:));
		if (homePlain) { %init(HomePressUp); [installed addObject:@"home button"]; }
		if (homeSource) { %init(HomePressUpWithSource); [installed addObject:@"home button (source)"]; }
		Class uiController = objc_getClass("SBUIController");
		if (!homePlain && !homeSource && JRFHasMethod(uiController, @selector(handleHomeButtonSinglePressUpWithSourceType:))) {
			%init(HomePressUIController);
			[installed addObject:@"home button (SBUIController)"];
		}
		if (JRFHasMethod(objc_getClass("SpringBoard"), @selector(frontDisplayDidChange:))) {
			%init(FrontDisplay);
			[installed addObject:@"app launch (front display)"];
		} else if (JRFHasMethod(objc_getClass("SBHIconManager"), @selector(launchFromIconView:withActions:))) {
			%init(IconLaunch);
			[installed addObject:@"app launch (icons only)"];
		}
		JRFDiagSet(@"optional hooks", [installed componentsJoinedByString:@", "]);
		JRFDiagSet(@"has iconCoordinateForIndex:metrics:", JRFYesNo(JRFHasMethod(dockList, @selector(iconCoordinateForIndex:metrics:))));
		JRFDiagSet(@"has cached metrics ivar", JRFYesNo(dockList && (class_getInstanceVariable(dockList, "_cachedMetrics") != NULL)));

		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, JRFPrefsChanged,
			CFSTR(JRFPrefsChangedNotification), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
		JRFDiagSet(@"build", JRFImageDescription());
		JRFStartFreezeWatchdog();
		JRFDiagSet(@"freeze watchdog", gWatchdogTimer ? @"running" : @"not running");
		JRFDiagEvent(@"Loaded: %lu dock pages, up to %d apps each", (unsigned long)gPages, JRFAppsPerPage);
		JRFDiagWrite();
	}
}
