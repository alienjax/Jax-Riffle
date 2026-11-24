#import <Foundation/Foundation.h>
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>
#import "JRFRootListController.h"

// Looked up at runtime, so the bundle doesn't need to link these private frameworks.
@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

static const NSUInteger JRFRelaunchFadeToBlack = 1 << 2; // SBSRelaunchActionOptionsFadeToBlackTransition

static NSString *const JRFPrefsDomain = @"com.alienjax.riffle";
// Written by the tweak when it switches itself off after a problem (it then stays off until turned back on).
static NSString *const JRFSafetyPath = @"/var/mobile/Library/Preferences/com.alienjax.riffle.safety.plist";

@implementation JRFRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		NSMutableArray *specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
		NSDictionary *record = [self switchOffRecord];
		if (record) {
			PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Switched Off" target:self set:NULL get:NULL
			                                                    detail:Nil cell:PSGroupCell edit:Nil];
			[group setProperty:[self switchOffMessage:record] forKey:@"footerText"];
			PSSpecifier *button = [PSSpecifier preferenceSpecifierNamed:@"Turn Back On" target:self set:NULL get:NULL
			                                                     detail:Nil cell:PSButtonCell edit:Nil];
			button.buttonAction = @selector(turnBackOn);
			[specifiers insertObject:group atIndex:0];
			[specifiers insertObject:button atIndex:1];
		}
		_specifiers = specifiers;
	}
	return _specifiers;
}

// The tweak's switch-off record, if it applies to the installed version and hasn't been cleared yet.
- (NSDictionary *)switchOffRecord {
	NSData *data = [NSData dataWithContentsOfFile:JRFSafetyPath];
	if (!data) return nil;
	id record = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
	if (![record isKindOfClass:[NSDictionary class]]) return nil;
	id tripped = record[@"tripped"];
	if (![tripped respondsToSelector:@selector(boolValue)] || ![tripped boolValue]) return nil;

	// A record from another version is cleared by the tweak on its next launch.
	NSString *installed = [[NSBundle bundleForClass:[self class]] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	if (installed && [record[@"version"] isKindOfClass:[NSString class]] && ![record[@"version"] isEqualToString:installed]) return nil;

	// Already turned back on, waiting for the respring.
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:JRFPrefsDomain];
	id turnedBackOn = [defaults objectForKey:@"turnedBackOnAt"];
	id date = record[@"date"];
	if ([turnedBackOn isKindOfClass:[NSDate class]] && [date isKindOfClass:[NSDate class]] &&
	    [(NSDate *)turnedBackOn compare:(NSDate *)date] != NSOrderedAscending) return nil;
	return record;
}

- (NSString *)switchOffMessage:(NSDictionary *)record {
	NSString *when = @"";
	if ([record[@"date"] isKindOfClass:[NSDate class]]) {
		NSDateFormatter *formatter = [NSDateFormatter new];
		formatter.dateStyle = NSDateFormatterMediumStyle;
		formatter.timeStyle = NSDateFormatterShortStyle;
		when = [NSString stringWithFormat:@" on %@", [formatter stringFromDate:record[@"date"]]];
	}
	NSString *reason = [record[@"reason"] isKindOfClass:[NSString class]] && [record[@"reason"] length] ? record[@"reason"] : @"something went wrong";
	return [NSString stringWithFormat:@"Switched off%@ because %@. Send the diagnostics below to the developer, then turn it back on.",
	                                   when, reason];
}

- (void)turnBackOn {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Turn Back On?"
	                                                               message:@"Your iPhone will respring."
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Turn On" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:JRFPrefsDomain];
		[defaults setObject:[NSDate date] forKey:@"turnedBackOnAt"];
		[defaults synchronize];
		[[NSFileManager defaultManager] removeItemAtPath:JRFSafetyPath error:NULL];
		// Give cfprefsd a moment to store the setting before SpringBoard restarts and reads it.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self performRespring];
		});
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)respring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
	                                                               message:nil
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		[self performRespring];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

// Puts the tweak's report about how it laid out the dock on the clipboard, ready to paste to the developer.
- (void)copyDiagnostics {
	NSString *path = @"/var/mobile/Library/Preferences/com.alienjax.riffle.diagnostics.txt";
	NSString *report = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
	NSString *title = nil, *message = nil;
	if (report.length > 0) {
		UIPasteboard.generalPasteboard.string = report;
		title = @"Copied";
		message = @"Paste it in a message to the developer.";
	} else {
		title = @"No Report Yet";
		message = @"Respring, then try again.";
	}
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)performRespring {
	dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
	dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
	Class actionClass = NSClassFromString(@"SBSRelaunchAction");
	Class serviceClass = NSClassFromString(@"FBSSystemService");
	if (!actionClass || !serviceClass) return;
	id action = [(id)actionClass actionWithReason:@"RestartRenderServer" options:JRFRelaunchFadeToBlack targetURL:nil];
	if (action) [[(id)serviceClass sharedService] sendActions:[NSSet setWithObject:action] withResult:nil];
}

@end
