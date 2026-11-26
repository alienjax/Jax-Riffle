// Jax Riffle: page transitions
// How each dock app looks while its page is part-way on screen. Only Core Animation transforms, so the
// maths can be checked away from the device too.

typedef NS_ENUM(NSInteger, JRFTransition) {
	JRFTransitionScroll = 0, // SpringBoard's own: the pages slide past
	JRFTransitionCube,       // the pages are the sides of a turning cube
	JRFTransitionFlip,       // the dock turns over like a card, with the next page on its back
	JRFTransitionCards,      // the later page slides over the earlier one, which shrinks and fades beneath it
	JRFTransitionFade,       // the page fades out where it is, then the next one fades in
	JRFTransitionZoom,       // the page grows and fades out, then the next one settles into place from smaller
};

typedef struct JRFAppLook {
	CATransform3D transform; // for the app's layer, which turns and scales around the app's own centre
	CGFloat alpha;           // times the app's own alpha
	CGFloat zPosition;       // added to the app's own (Cards keeps the later page on top)
} JRFAppLook;

// Moves along the dock (sideways for a dock along the bottom).
static inline CATransform3D JRFAlongDock(CGFloat distance, BOOL horizontal) {
	return horizontal ? CATransform3DMakeTranslation(distance, 0, 0) : CATransform3DMakeTranslation(0, distance, 0);
}

// Turns about the axis across the dock. A negative angle brings the end of the dock that's further along
// (right, or bottom) towards you, as when a page leaves.
static inline CATransform3D JRFTurn(CGFloat angle, BOOL horizontal) {
	return horizontal ? CATransform3DMakeRotation(angle, 0, 1, 0) : CATransform3DMakeRotation(-angle, 1, 0, 0);
}

// How an app looks part-way through a page change.
//  t       where the app's page is, in pages from the one on screen: 0 on screen, -1 the page before (gone off
//          the left end), +1 the page after (off the right end). Pages at -1 or +1 and beyond just slide.
//  x       how far the app's centre is from the middle of the dock, along the dock, where the pages are now
//  length  one page, along the dock
static JRFAppLook JRFTransitionLook(JRFTransition style, CGFloat t, CGFloat x, CGFloat length, BOOL horizontal) {
	JRFAppLook look = { CATransform3DIdentity, 1.0, 0.0 };
	if (style == JRFTransitionScroll || !(length > 0) || !(fabs(t) < 1.0) || !isfinite(x)) return look;

	CGFloat progress = fabs(t);
	CATransform3D move;        // what happens to the page, around the middle of the dock
	BOOL inPerspective = NO;
	switch (style) {
		case JRFTransitionCube: {
			// A side of a cube whose middle is half a page behind the dock. A quarter turn per page brings the
			// next side round, so the page is held in the middle and the turn alone moves it.
			CGFloat half = length / 2.0;
			move = JRFAlongDock(-t * length, horizontal);
			move = CATransform3DConcat(move, CATransform3DMakeTranslation(0, 0, half));
			move = CATransform3DConcat(move, JRFTurn(t * M_PI_2, horizontal));
			move = CATransform3DConcat(move, CATransform3DMakeTranslation(0, 0, -half));
			inPerspective = YES;
			break;
		}
		case JRFTransitionFlip:
			// Turns over where it is. The next page is on the back, so each shows for half of the swipe.
			if (progress >= 0.5) {
				look.alpha = 0;
				return look;
			}
			move = CATransform3DConcat(JRFAlongDock(-t * length, horizontal), JRFTurn(t * M_PI, horizontal));
			inPerspective = YES;
			break;
		case JRFTransitionCards: {
			// The later page slides over the top. The earlier one stays where it is, shrinks a little and fades,
			// so it has gone by the time the later page covers its place.
			if (t >= 0) {
				look.zPosition = 1;
				return look;
			}
			CGFloat scale = 1.0 + 0.15 * t;
			move = CATransform3DConcat(JRFAlongDock(-t * length, horizontal), CATransform3DMakeScale(scale, scale, 1));
			look.alpha = 1.0 + t;
			break;
		}
		case JRFTransitionFade:
			// Fades out where it is; the next page then fades in where it will be.
			move = JRFAlongDock(-t * length, horizontal);
			look.alpha = MAX((CGFloat)0, (CGFloat)1.0 - 2.0 * progress);
			break;
		case JRFTransitionZoom: {
			// Leaving, the page grows as it fades (towards you); the next one comes in smaller and grows into
			// place. Swiping back runs it in reverse.
			CGFloat scale = 1.0 - 0.3 * t;
			move = CATransform3DConcat(JRFAlongDock(-t * length, horizontal), CATransform3DMakeScale(scale, scale, 1));
			look.alpha = MAX((CGFloat)0, (CGFloat)1.0 - 2.0 * progress);
			break;
		}
		default:
			return look;
	}

	if (inPerspective) {
		CATransform3D perspective = CATransform3DIdentity;
		perspective.m34 = -1.0 / (2.0 * length); // seen from two pages' distance, centred on the dock
		move = CATransform3DConcat(move, perspective);
	}
	// The app's layer works around its own centre, which is x from the middle of the dock.
	look.transform = CATransform3DConcat(CATransform3DConcat(JRFAlongDock(x, horizontal), move), JRFAlongDock(-x, horizontal));
	return look;
}
