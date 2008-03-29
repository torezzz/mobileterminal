// MobileTerminal.h
#define DEBUG_METHOD_TRACE    0

#import "MobileTerminal.h"
#import <Foundation/Foundation.h>
#import <GraphicsServices/GraphicsServices.h>
#import "ShellKeyboard.h"
#import "PTYTextView.h"
#import "SubProcess.h"
#import "VT100Terminal.h"
#import "VT100Screen.h"
#import "GestureView.h"
#import "PieView.h"
#import "Preferences.h"
#import "Settings.h"

#import <UIKit/UIView-Geometry.h>
#import <LayerKit/LKAnimation.h>
#import <CoreGraphics/CoreGraphics.h>

//_______________________________________________________________________________
//_______________________________________________________________________________

@implementation MobileTerminal

@synthesize landscape, degrees, controlKeyMode;

static MobileTerminal * application;

//_______________________________________________________________________________

+ (MobileTerminal*) application
{
	return application;
	//return [[UIWindow keyWindow] application];
}

//_______________________________________________________________________________

- (void) applicationDidFinishLaunching:(NSNotification*)unused
{
	log(@"applicationDidFinishLaunching");
	
	application = self;
	
	int i;
	
	settings = [[Settings sharedInstance] retain];
	[settings registerDefaults];
	[settings readUserDefaults];

	activeTerminal = 0;
	lastTerminal = -1;
	
  controlKeyMode = NO;
  keyboardShown = YES;

	degrees = 0;
	landscape = NO;
	
	CGSize screenSize = [UIHardware mainScreenSize];
  CGRect frame = CGRectMake(0, 0, screenSize.width, screenSize.height);

	processes = [[NSMutableArray arrayWithCapacity: MAXTERMINALS] retain];
  screens   = [[NSMutableArray arrayWithCapacity: MAXTERMINALS] retain];
  terminals = [[NSMutableArray arrayWithCapacity: MAXTERMINALS] retain];
	scrollers = [[NSMutableArray arrayWithCapacity: MAXTERMINALS] retain];
	textviews = [[NSMutableArray arrayWithCapacity: MAXTERMINALS] retain];
  	
	for (numTerminals = 0; numTerminals < ([settings multipleTerminals] ? MAXTERMINALS : 1); numTerminals++)
	{
		VT100Terminal * terminal = [[VT100Terminal alloc] init];
		VT100Screen   * screen   = [[VT100Screen alloc] initWithIdentifier: numTerminals];
		SubProcess    * process  = [[SubProcess alloc] initWithDelegate:self identifier: numTerminals];
		UIScroller    * scroller = [[UIScroller alloc] init];
		
		[screens   addObject: screen];
		[terminals addObject: terminal];
		[processes addObject: process];
		[scrollers addObject: scroller];
		
		[screen setTerminal:terminal];
		[terminal setScreen:screen];		
		
		PTYTextView * textview = [[PTYTextView alloc] initWithFrame: CGRectMake(0.0f, 0.0f, 320.0f, 244.0f)
																												 source: screen
																											 scroller: scroller
																										 identifier: numTerminals];		
		[textviews addObject:textview];
	}
	
  keyboardView = [[[ShellKeyboard alloc] initWithFrame:CGRectMake(0.0f, 244.0f, 320.0f, 460.0f-244.0f)] retain];
  [keyboardView setInputDelegate:self];

	CGRect gestureFrame = CGRectMake(0.0f, 0.0f, 240.0f, 250.0f);
  gestureView = [[GestureView alloc] initWithFrame:gestureFrame delegate:self];

  mainView = [[[UIView alloc] initWithFrame:frame] retain];
	[mainView setBackgroundColor:[UIView colorWithRed:0.0f green:0.0f blue:0.0f alpha:1.0f]];
	for (i = 0; i < numTerminals; i++)
		[mainView addSubview:[scrollers objectAtIndex:i]];
  [mainView addSubview:gestureView];
  [mainView addSubview:keyboardView];	
  [mainView addSubview:[keyboardView inputView]];
  [mainView addSubview:[PieView sharedInstance]];
	activeView = mainView;

	contentView = [[UITransitionView alloc] initWithFrame: frame];
	[contentView addSubview:mainView];
	
	window = [[UIWindow alloc] initWithFrame: frame];
	[window setContentView: contentView]; 
	[window orderFront: self];
	[window makeKey: self];
	[window _setHidden: NO];
	[window retain];	
			
  // Shows momentarily and hides so the user knows its there
  [[PieView sharedInstance] hideSlow:YES];

  // Input focus
  [[keyboardView inputView] becomeFirstResponder];
		
	for (i = 1; i < numTerminals; i++)
	{
		[self setActiveTerminal:i];
	}
	
	[self setActiveTerminal:0];
	
	log(@"app init finished");
}

//_______________________________________________________________________________

-(UIView*) mainView { return mainView; }
-(UIView*) activeView { return activeView; }
-(PTYTextView*) textView { return [textviews objectAtIndex:activeTerminal]; }
-(UIScroller*) textScroller { return [scrollers objectAtIndex:activeTerminal]; }

// Suspend/Resume: We have to hide then show again the keyboard view to get it
// to properly acheive focus on suspend and resume.

//_______________________________________________________________________________

- (void)applicationResume:(GSEvent *)event
{
	if (keyboardShown)
	{
		[mainView addSubview:keyboardView];
	}
	
	[mainView addSubview:[keyboardView inputView]];
	[[keyboardView inputView] becomeFirstResponder];
	
	[self setActiveTerminal:0];
	[self updateStatusBar];
}

//_______________________________________________________________________________

- (void)applicationSuspend:(GSEvent *)event
{
	BOOL shouldQuit;
	int i;
	shouldQuit = YES;
	
	[settings writeUserDefaults];
	
	for (i = 0; i < [processes count]; i++) {
		if ([ [processes objectAtIndex: i] isRunning]) {
			shouldQuit = NO;
			break;
		}
	}
	
  if (shouldQuit) {		
    exit(0);
  }

  [[keyboardView inputView] removeFromSuperview];
  [keyboardView removeFromSuperview];
	
	for (i = 0; i < MAXTERMINALS; i++)
		[self removeStatusBarImageNamed:[NSString stringWithFormat:@"MobileTerminal%d", i]];
}

//_______________________________________________________________________________

- (void)applicationExited:(GSEvent *)event
{
	int i;
	
	[settings writeUserDefaults];
	
	for (i = 0; i < [processes count]; i++) {
		[[processes objectAtIndex: i] close];
	}	

	for (i = 0; i < MAXTERMINALS; i++)
		[self removeStatusBarImageNamed:[NSString stringWithFormat:@"MobileTerminal%d", i]];
}

//_______________________________________________________________________________

// Process output from the shell and pass it to the screen
- (void)handleStreamOutput:(const char*)c length:(unsigned int)len identifier:(int)tid
{
	if (tid < 0 || tid >= [terminals count]) {
		return;
  }
	
  VT100Terminal* terminal = [terminals objectAtIndex: tid];
  VT100Screen* screen = [screens objectAtIndex: tid];
  	
  [terminal putStreamData:c length:len];

  // Now that we've got the raw data from the sub process, write it to the
  // terminal.  We get back tokens to display on the screen and pass the
  // update in the main thread.
  VT100TCC token;
  while((token = [terminal getNextToken]),
    token.type != VT100_WAIT && token.type != VT100CC_NULL) {
    // process token
    if (token.type != VT100_SKIP) {
      if (token.type == VT100_NOTSUPPORT) {
        NSLog(@"%s(%d):not support token", __FILE__ , __LINE__);
      } else {
        [screen putToken:token];
      }
    } else {
      NSLog(@"%s(%d):skip token", __FILE__ , __LINE__);
    }
  }
	
  if (tid == activeTerminal) 
	{
		[[self textView] performSelectorOnMainThread:@selector(updateAndScrollToEnd)
																			withObject:nil
																	 waitUntilDone:NO];
	}	
}

//_______________________________________________________________________________

// Process input from the keyboard
- (void)handleKeyPress:(unichar)c
{
  //log(@"c=0x%02x)", c);

  if (!controlKeyMode) 
	{
    if (c == 0x2022) 
		{
      controlKeyMode = YES;
      return;
    }
		else if (c == 0x0a) // LF from keyboard RETURN
		{
			c = 0x0d; // convert to CR
		}
  } 
	else 
	{
    // was in ctrl key mode, got another key
    if (c < 0x60 && c > 0x40) 
		{
      // Uppercase
      c -= 0x40;
    } 
		else if (c < 0x7B && c > 0x60) 
		{
      // Lowercase
      c -= 0x60;
    }
    controlKeyMode = NO;
  }
  // Not sure if this actually matches anything.  Maybe support high bits later?
  if ((c & 0xff00) != 0) 
	{
    NSLog(@"Unsupported unichar: %x", c);
    return;
  }
  char simple_char = (char)c;
	
  [[self activeProcess] write:&simple_char length:1];
}

//_______________________________________________________________________________

-(CGPoint) viewPointForWindowPoint:(CGPoint)point
{
	return [mainView convertPoint:point fromView:window];
}

//_______________________________________________________________________________

- (void)hideMenu
{
  [[PieView sharedInstance] hide];
}

//_______________________________________________________________________________

- (void)showMenu:(CGPoint)point
{
  [[PieView sharedInstance] showAtPoint:point];
}

//_______________________________________________________________________________

- (void)handleInputFromMenu:(NSString*)input
{
  [[self activeProcess] write:[input cString] length:[input length]];
}

//_______________________________________________________________________________

- (void)toggleKeyboard
{
	if (keyboardShown) 
	{
		keyboardShown = NO;
		[keyboardView removeFromSuperview];
	}
	else
	{
		keyboardShown = YES;
		[mainView addSubview:keyboardView];		
	}
		
	[self updateFrames:NO];
}

//_______________________________________________________________________________

-(void) setControlKeyMode:(BOOL)mode
{
	// log(@"setControlMode: %d", mode);
	controlKeyMode = mode;
	[[self textView] refreshCursorRow];
}

//_______________________________________________________________________________

- (void) statusBarMouseUp:(GSEvent*)event
{
	if (numTerminals > 1)
	{
		CGPoint pos = GSEventGetLocationInWindow(event);
		float width = landscape ? window.frame.size.height : window.frame.size.width;
		if (pos.x > width/2 && pos.x < width*3/4)
		{
			[self prevTerminal];
		}
		else if (pos.x > width*3/4)
		{
			[self nextTerminal];
		}
		else
		{
			if (activeView == mainView)
				[self togglePreferences];
		}
	}
	else
	{
		if (activeView == mainView)
			[self togglePreferences];
	}
}	

//_______________________________________________________________________________

- (void) deviceOrientationChanged: (GSEvent*)event 
{
	switch ([UIHardware deviceOrientation:YES])
	{
		case 1: [self setOrientation:  0]; break;
		case 3: [self setOrientation: 90]; break;
		case 4: [self setOrientation:-90]; break;
	}
}

//_______________________________________________________________________________
-(void) setOrientation:(int)angle
{
	log(@"angle %d", angle);
	if (degrees == angle || activeView != mainView) return;

	struct CGAffineTransform transEnd;
	switch(angle) 
	{
		case  90: transEnd = CGAffineTransformMake(0,  1, -1, 0, 0, 0); landscape = true;  break;
		case -90: transEnd = CGAffineTransformMake(0, -1,  1, 0, 0, 0); landscape = true;  break;
		case   0: transEnd = CGAffineTransformMake(1,  0,  0, 1, 0, 0); landscape = false; break;
		default:  return;
	}

	CGSize screenSize = [UIHardware mainScreenSize];
	CGRect contentBounds;

	if (landscape)
		contentBounds = CGRectMake(0, 0, screenSize.height, screenSize.width);
	else
		contentBounds = CGRectMake(0, 0, screenSize.width, screenSize.height);

	[UIView beginAnimations:@"screenRotation"];
	[UIView setAnimationDelegate:self];
	[UIView setAnimationDidStopSelector: @selector(animationDidStop:finished:context:)];
	[contentView setTransform:transEnd];
	[contentView setBounds:contentBounds];
	[UIView endAnimations];

	degrees = angle;
	[self updateStatusBar];
}

//_______________________________________________________________________________

-(void) updateStatusBar
{
	[self setStatusBarMode: [self statusBarMode]
						 orientation: degrees
								duration: 0.5 
								 fenceID: 0 
							 animation: 0];	
}

//_______________________________________________________________________________

- (void) updateFrames:(BOOL)needsRefresh
{
	CGRect contentRect;
	CGRect textFrame;
	CGRect textScrollerFrame;
	CGRect gestureFrame;
	int columns, rows;
	
	//log(@"----------------- updateFrames needsRefresh %d", needsRefresh);

	struct CGSize size = [UIHardware mainScreenSize];
	CGSize keybSize = [UIKeyboard defaultSizeForOrientation:(landscape ? 90 : 0)];

	float statusBarHeight = [UIHardware statusBarHeight];
	
	if (landscape) contentRect = CGRectMake(0, statusBarHeight, size.height, size.width-statusBarHeight);
	else           contentRect = CGRectMake(0, statusBarHeight, size.width, size.height-statusBarHeight);

	[mainView setFrame:contentRect];
		
	TerminalConfig * config = [[[Settings sharedInstance] terminalConfigs] objectAtIndex:activeTerminal];

	float availableWidth = mainView.bounds.size.width;
	float availableHeight= mainView.bounds.size.height;
	
	if (keyboardShown) 
	{
		availableHeight -= keybSize.height;
		[keyboardView setFrame:CGRectMake(0, mainView.bounds.size.height - keybSize.height, availableWidth, keybSize.height)];
	}
			
	float lineHeight = [config fontSize] + TERMINAL_LINE_SPACING;
	float charWidth  = [config fontSize]*[config fontWidth];
	
	rows = availableHeight / lineHeight;
	
	if ([config autosize])
	{
		columns = availableWidth / charWidth;
	}
	else
	{
		columns = [config width];
	}

	textFrame				  = CGRectMake(0.0f, 0.0f, columns * charWidth, rows * lineHeight);
	gestureFrame			= CGRectMake(0.0f, 0.0f, availableWidth-40.0f, availableHeight-(columns * charWidth > availableWidth ? 40.0f : 0));
	textScrollerFrame = CGRectMake(0.0f, 0.0f, availableWidth, availableHeight);

	[[self textView]     setFrame:textFrame];
	[[self textScroller] setFrame:textScrollerFrame];
	[[self textScroller] setContentSize:textFrame.size];
	[gestureView         setFrame:gestureFrame];
	
	[[self activeProcess] setWidth:columns    height:rows];
	[[self activeScreen]  resizeWidth:columns height:rows];
		
	if (needsRefresh) 
	{
		[[self textView] refresh];	
		[[self textView] updateIfNecessary];
	}
}

//_______________________________________________________________________________

-(void) setActiveTerminal:(int)active
{
	[self setActiveTerminal:active direction:0];
}

//_______________________________________________________________________________

-(void) setActiveTerminal:(int)active direction:(int)direction
{
	lastTerminal = activeTerminal;
	
	[[self textView] willSlideOut];
		
	if (direction)
	{
		[UIView beginAnimations:@"slideOut"];
		[UIView setAnimationDelegate:self];
		[UIView setAnimationDidStopSelector: @selector(animationDidStop:finished:context:)];
		[(UIView*)[self textScroller] setTransform:CGAffineTransformMakeTranslation(-direction * [mainView frame].size.width,0)];
		[UIView endAnimations];
	}
	else
	{
		[(UIView*)[self textScroller] setTransform:CGAffineTransformMakeTranslation(-[mainView frame].size.width,0)];
	}
	
	if (numTerminals > 1) [self removeStatusBarImageNamed:[NSString stringWithFormat:@"MobileTerminal%d", activeTerminal]];
	
	activeTerminal = active;
	
	if (numTerminals > 1)	[self addStatusBarImageNamed:[NSString stringWithFormat:@"MobileTerminal%d", activeTerminal] 
																removeOnAbnormalExit:YES];
	
	if (direction)
	{
		[(UIView*)[self textScroller] setTransform:CGAffineTransformMakeTranslation(direction * [mainView frame].size.width,0)];
		
		[UIView beginAnimations:@"slideIn"];
		//[UIView setAnimationDelegate:self];
		//[UIView setAnimationDidStopSelector: @selector(animationDidStop:finished:context:)];
		[(UIView*)[self textScroller] setTransform:CGAffineTransformMakeTranslation(0,0)];
		[UIView endAnimations];
	}
	else
	{
		[(UIView*)[self textScroller] setTransform:CGAffineTransformMakeTranslation(0,0)];
	}
		
	[self updateFrames:YES];
	
	[[self textView] willSlideIn];
}

//_______________________________________________________________________________

- (void) animationDidStop:(NSString*)animationID finished:(NSNumber*)finished context:(void*)context 
{
	//log(@"animation did stop %@ finished %@", animationID, finished);
	// move old terminal away, so it won't appear on screen rotation
	if ([animationID isEqualToString:@"slideOut"])
		[[scrollers objectAtIndex:lastTerminal] setPosition:CGPointMake(1000,0)];
	else if ([animationID isEqualToString:@"screenRotation"])
		[self updateFrames:YES];
}

//_______________________________________________________________________________

-(void) prevTerminal
{
	int active = activeTerminal - 1;
	if (active < 0) active = numTerminals-1;
	[self setActiveTerminal:active direction:-1];
}

//_______________________________________________________________________________

-(void) nextTerminal
{
	int active = activeTerminal + 1;
	if (active >= numTerminals) active = 0;
	[self setActiveTerminal:active direction:1];
}

//_______________________________________________________________________________

-(void) createTerminals
{
	for (numTerminals = 1; numTerminals < MAXTERMINALS; numTerminals++)
	{
		VT100Terminal * terminal = [[VT100Terminal alloc] init];
		VT100Screen   * screen   = [[VT100Screen alloc] init];
		SubProcess    * process  = [[SubProcess alloc] initWithDelegate:self identifier: numTerminals];
		UIScroller    * scroller = [[UIScroller alloc] init];
		
		[screens   addObject: screen];
		[terminals addObject: terminal];
		[processes addObject: process];
		[scrollers addObject: scroller];
		
		[screen setTerminal:terminal];
		[terminal setScreen:screen];		
		
		PTYTextView * textview = [[PTYTextView alloc] initWithFrame: CGRectMake(0.0f, 0.0f, 320.0f, 244.0f)
																												 source: screen
																											 scroller: scroller
																										 identifier: numTerminals];		
		[textviews addObject:textview];
	}	
	
	[self addStatusBarImageNamed:[NSString stringWithFormat:@"MobileTerminal0"] removeOnAbnormalExit:YES];
}

//_______________________________________________________________________________

-(void) destroyTerminals
{
	[self setActiveTerminal:0];
	
	[self removeStatusBarImageNamed:[NSString stringWithFormat:@"MobileTerminal0"]];
	
	for (numTerminals = MAXTERMINALS; numTerminals > 1; numTerminals--)
	{
		SubProcess * process = [processes lastObject];
		[process closeSession];
		[[textviews lastObject] removeFromSuperview];
		
		[screens   removeLastObject];
		[terminals removeLastObject];
		[processes removeLastObject];
		[scrollers removeLastObject];
		[textviews removeLastObject];
	}
}
	
//_______________________________________________________________________________

-(void) togglePreferences
{
	if (preferencesController == nil) 
	{
		preferencesController = [PreferencesController sharedInstance];
		[preferencesController initViewStack];
	}

	LKAnimation * animation = [LKTransition animation];
	// to make the compiler not complain
	//[animation setType: @"oglFlip"];
	//[animation setSubtype: (activeView == mainView) ? @"fromRight" : @"fromLeft"];
	//[animation setTransitionFlags: 3];
	[animation performSelector:@selector(setType:) withObject:@"oglFlip"];
	[animation performSelector:@selector(setSubtype:) withObject:(activeView == mainView) ? @"fromRight" : @"fromLeft"];
	[animation performSelector:@selector(setTransitionFlags:) withObject:[NSNumber numberWithInt:3]];
	[animation setTimingFunction: [LKTimingFunction functionWithName: @"easeInEaseOut"]];
	[animation setFillMode: @"extended"];
	[animation setSpeed: 0.25f];
	[contentView addAnimation:(id)animation forKey:@"flip"];	
	
	if (activeView == mainView)
	{
		if (landscape) [self setOrientation:0];
		[contentView transition:0 toView:[preferencesController view]];
		activeView = [preferencesController view];
	}
	else
	{
		[contentView transition:0 toView:mainView];
		activeView = mainView;
		
		[settings writeUserDefaults];
		
		if (numTerminals > 1 && ![settings multipleTerminals])
		{
			[self destroyTerminals];
		}
		else if (numTerminals == 1 && [settings multipleTerminals])
		{
			[self createTerminals];
		}
	}
}

//_______________________________________________________________________________

-(SubProcess*) activeProcess
{
	return [processes objectAtIndex: activeTerminal];
}

-(VT100Screen*) activeScreen
{
	return [screens objectAtIndex: activeTerminal];
}

-(VT100Terminal*) activeTerminal
{
	return [terminals objectAtIndex: activeTerminal];
}

-(NSArray *) textviews
{
	return textviews;
}

@end