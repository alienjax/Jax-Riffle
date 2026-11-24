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

@implementation JRFRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

- (void)respring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
	                                                               message:@"Page count and Enabled changes take effect after a respring."
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
		message = @"The dock report is on the clipboard. Paste it into your message to the developer.";
	} else {
		title = @"No Report Yet";
		message = [NSString stringWithFormat:@"Respring with the tweak enabled, go to the Home Screen, then try again.\n\n%@", path];
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
