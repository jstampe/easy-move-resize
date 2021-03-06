#import "EMRAppDelegate.h"
#import "EMRMoveResize.h"
#import "EMRPreferences.h"

@implementation EMRAppDelegate

CGEventRef myCGEventCallback(CGEventTapProxy __unused proxy, CGEventType type, CGEventRef event, void *refcon) {

    EMRAppDelegate *ourDelegate = (__bridge EMRAppDelegate*)refcon;
    int keyModifierFlags = [ourDelegate modifierFlags];
    if (keyModifierFlags == 0) {
        // No modifier keys set. Disable behaviour.
        return event;
    }

    BOOL useMouseMove = [ourDelegate useMouseMove];
    
    EMRMoveResize* moveResize = [EMRMoveResize instance];

    if ((type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput)) {
        // need to re-enable our eventTap (We got disabled.  Usually happens on a slow resizing app)
        CGEventTapEnable([moveResize eventTap], true);
        NSLog(@"Re-enabling...");
        return event;
    }
    
    CGEventFlags flags = CGEventGetFlags(event);
    if ((flags & (keyModifierFlags)) != (keyModifierFlags)) {
        // Disable tracking if enabled - modifiers are not pressed.
        if ([moveResize tracking] > 0) {
            [moveResize setTracking:0];
        }
        return event;
    }

    int ignoredKeysMask = (kCGEventFlagMaskShift | kCGEventFlagMaskCommand | kCGEventFlagMaskAlphaShift | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl) ^ keyModifierFlags;
    
    if (flags & ignoredKeysMask) {
        NSLog(@"flags & ignoredKeysMask");
        // also ignore this event if we've got extra modifiers (i.e. holding down Cmd+Ctrl+Alt should not invoke our action)
        return event;
    }

    if ((useMouseMove && type == kCGEventMouseMoved && [moveResize tracking] == 0) // With mouse move
     || (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown)) {  // With click
        CGPoint mouseLocation = CGEventGetLocation(event);
        [moveResize setTracking:1];

        AXUIElementRef _systemWideElement;
        AXUIElementRef _clickedWindow = NULL;
        _systemWideElement = AXUIElementCreateSystemWide();

        AXUIElementRef _element;
        if ((AXUIElementCopyElementAtPosition(_systemWideElement, (float) mouseLocation.x, (float) mouseLocation.y, &_element) == kAXErrorSuccess) && _element) {
            CFTypeRef _role;
            if (AXUIElementCopyAttributeValue(_element, (__bridge CFStringRef)NSAccessibilityRoleAttribute, &_role) == kAXErrorSuccess) {
                if ([(__bridge NSString *)_role isEqualToString:NSAccessibilityWindowRole]) {
                    _clickedWindow = _element;
                }
                if (_role != NULL) CFRelease(_role);
            }
            CFTypeRef _window;
            if (AXUIElementCopyAttributeValue(_element, (__bridge CFStringRef)NSAccessibilityWindowAttribute, &_window) == kAXErrorSuccess) {
                if (_element != NULL) CFRelease(_element);
                _clickedWindow = (AXUIElementRef)_window;
            }
        }
        CFRelease(_systemWideElement);

        CFTypeRef _cPosition = nil;
        NSPoint cTopLeft;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)_clickedWindow, (__bridge CFStringRef)NSAccessibilityPositionAttribute, &_cPosition) == kAXErrorSuccess) {
            if (!AXValueGetValue(_cPosition, kAXValueCGPointType, (void *)&cTopLeft)) {
                NSLog(@"ERROR: Could not decode position");
                cTopLeft = NSMakePoint(0, 0);
            }
            CFRelease(_cPosition);
        }
        
        cTopLeft.x = (int) cTopLeft.x;
        cTopLeft.y = (int) cTopLeft.y;

        [moveResize setWndPosition:cTopLeft];
        [moveResize setWindow:_clickedWindow];
        if (_clickedWindow != nil) CFRelease(_clickedWindow);
    }

    if ((useMouseMove && type == kCGEventMouseMoved && [moveResize tracking] > 0)  // With move
        || (type == kCGEventLeftMouseDragged && [moveResize tracking] > 0)) {      // With clicks

        [moveResize setTracking:[moveResize tracking] + 1];
        AXUIElementRef _clickedWindow = [moveResize window];
        double deltaX = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
        double deltaY = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);

        NSPoint cTopLeft = [moveResize wndPosition];
        NSPoint thePoint;
        thePoint.x = cTopLeft.x + deltaX;
        thePoint.y = cTopLeft.y + deltaY;
        [moveResize setWndPosition:thePoint];
        CFTypeRef _position;

        // actually applying the change is expensive, so only do it every kMoveFilterInterval events
        if ([moveResize tracking] % kMoveFilterInterval == 0) {
            _position = (CFTypeRef)(AXValueCreate(kAXValueCGPointType, (const void *)&thePoint));
            AXUIElementSetAttributeValue(_clickedWindow, (__bridge CFStringRef)NSAccessibilityPositionAttribute, (CFTypeRef *)_position);
            if (_position != NULL) CFRelease(_position);
        }
    }

    if (type == kCGEventRightMouseDown) {
        [moveResize setTracking:true];
        AXUIElementRef _clickedWindow = [moveResize window];

        // on right click, record which direction we should resize in on the drag
        struct ResizeSection resizeSection;

        CGPoint clickPoint = CGEventGetLocation(event);

        NSPoint cTopLeft = [moveResize wndPosition];

        clickPoint.x -= cTopLeft.x;
        clickPoint.y -= cTopLeft.y;

        CFTypeRef _cSize;
        NSSize cSize;
        if (!AXUIElementCopyAttributeValue((AXUIElementRef)_clickedWindow, (__bridge CFStringRef)NSAccessibilitySizeAttribute, &_cSize) == kAXErrorSuccess
                || !AXValueGetValue(_cSize, kAXValueCGSizeType, (void *)&cSize)) {
            NSLog(@"ERROR: Could not decode size");
            return NULL;
        }
        CFRelease(_cSize);

        NSSize wndSize = cSize;

        if (clickPoint.x < wndSize.width/3) {
            resizeSection.xResizeDirection = left;
        } else if (clickPoint.x > 2*wndSize.width/3) {
            resizeSection.xResizeDirection = right;
        } else {
            resizeSection.xResizeDirection = noX;
        }

        if (clickPoint.y < wndSize.height/3) {
            resizeSection.yResizeDirection = bottom;
        } else  if (clickPoint.y > 2*wndSize.height/3) {
            resizeSection.yResizeDirection = top;
        } else {
            resizeSection.yResizeDirection = noY;
        }

        [moveResize setWndSize:wndSize];
        [moveResize setResizeSection:resizeSection];
    }

    if (type == kCGEventRightMouseDragged
        && [moveResize tracking] > 0) {
        [moveResize setTracking:[moveResize tracking] + 1];

        AXUIElementRef _clickedWindow = [moveResize window];
        struct ResizeSection resizeSection = [moveResize resizeSection];
        int deltaX = (int) CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
        int deltaY = (int) CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);

        NSPoint cTopLeft = [moveResize wndPosition];
        NSSize wndSize = [moveResize wndSize];

        switch (resizeSection.xResizeDirection) {
            case right:
                wndSize.width += deltaX;
                break;
            case left:
                wndSize.width -= deltaX;
                cTopLeft.x += deltaX;
                break;
            case noX:
                // nothing to do
                break;
            default:
                [NSException raise:@"Unknown xResizeSection" format:@"No case for %d", resizeSection.xResizeDirection];
        }

        switch (resizeSection.yResizeDirection) {
            case top:
                wndSize.height += deltaY;
                break;
            case bottom:
                wndSize.height -= deltaY;
                cTopLeft.y += deltaY;
                break;
            case noY:
                // nothing to do
                break;
            default:
                [NSException raise:@"Unknown yResizeSection" format:@"No case for %d", resizeSection.yResizeDirection];
        }

        [moveResize setWndPosition:cTopLeft];
        [moveResize setWndSize:wndSize];

        // actually applying the change is expensive, so only do it every kResizeFilterInterval events
        if ([moveResize tracking] % kResizeFilterInterval == 0) {
            // only make a call to update the position if we need to
            if (resizeSection.xResizeDirection == left || resizeSection.yResizeDirection == bottom) {
                CFTypeRef _position = (CFTypeRef)(AXValueCreate(kAXValueCGPointType, (const void *)&cTopLeft));
                AXUIElementSetAttributeValue(_clickedWindow, (__bridge CFStringRef)NSAccessibilityPositionAttribute, (CFTypeRef *)_position);
                CFRelease(_position);
            }

            CFTypeRef _size = (CFTypeRef)(AXValueCreate(kAXValueCGSizeType, (const void *)&wndSize));
            AXUIElementSetAttributeValue((AXUIElementRef)_clickedWindow, (__bridge CFStringRef)NSAccessibilitySizeAttribute, (CFTypeRef *)_size);
            CFRelease(_size);
        }
    }

    if (type == kCGEventLeftMouseUp
            || type == kCGEventRightMouseUp) {
        [moveResize setTracking:0];
    }

    // we took ownership of this event, don't pass it along
    return NULL;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    if (!AXAPIEnabled()) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Cannot start Easy Move+Resize!\n\nOS X 10.9 (Mavericks) or later: visit\nSystem Preferences->Security & Privacy,\nand check \"Easy Move+Resize\" in the\nPrivacy tab\n\nOS X 10.8 (Mountain Lion): visit\nSystem Preferences->Accessibility\nand check \"Enable access for assistive devices\""];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        exit(1);
    }

    [self initModifierMenuItems];

    // Retrieve the Key press modifier flags to activate move/resize actions.
    keyModifierFlags = [EMRPreferences modifierFlags];

    CFRunLoopSourceRef runLoopSource;

    CGEventMask eventMask = CGEventMaskBit( kCGEventLeftMouseDown )
                    | CGEventMaskBit( kCGEventLeftMouseDragged )
                    | CGEventMaskBit( kCGEventRightMouseDown )
                    | CGEventMaskBit( kCGEventRightMouseDragged )
                    | CGEventMaskBit( kCGEventLeftMouseUp )
                    | CGEventMaskBit( kCGEventMouseMoved)
                    | CGEventMaskBit( kCGEventRightMouseUp )
    ;

    CFMachPortRef eventTap = CGEventTapCreate(kCGHIDEventTap,
                                              kCGHeadInsertEventTap,
                                              kCGEventTapOptionDefault,
                                              eventMask,
                                              myCGEventCallback,
                                              (__bridge void * _Nullable)self);

    if (!eventTap) {
        NSLog(@"Couldn't create event tap!");
        exit(1);
    }

    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);


    EMRMoveResize *moveResize = [EMRMoveResize instance];
    [moveResize setEventTap:eventTap];
    [moveResize setRunLoopSource:runLoopSource];
    [self enableRunLoopSource:moveResize];
    CFRelease(runLoopSource);
}

-(void)awakeFromNib{
    NSImage *icon = [NSImage imageNamed:@"MenuIcon"];
    NSImage *altIcon = [NSImage imageNamed:@"MenuIconHighlight"];
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [statusItem setMenu:statusMenu];
    [statusItem setImage:icon];
    [statusItem setAlternateImage:altIcon];
    [statusItem setHighlightMode:YES];
    [statusMenu setAutoenablesItems:NO];
    [[statusMenu itemAtIndex:0] setEnabled:NO];
}

- (void)enableRunLoopSource:(EMRMoveResize*)moveResize {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), [moveResize runLoopSource], kCFRunLoopCommonModes);
    CGEventTapEnable([moveResize eventTap], true);
}

- (void)disableRunLoopSource:(EMRMoveResize*)moveResize {
    CGEventTapEnable([moveResize eventTap], false);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), [moveResize runLoopSource], kCFRunLoopCommonModes);
}

- (void)initModifierMenuItems {
    [_altMenu setState:0];
    [_cmdMenu setState:0];
    [_ctrlMenu setState:0];
    [_shiftMenu setState:0];
    [_disabledMenu setState:0];
    [_useMouseMoveMenu setState: 0];
    NSSet* flags = [EMRPreferences getFlagStringSet];
    if ([flags containsObject:ALT_KEY]) {
        [_altMenu setState:1];
    }
    if ([flags containsObject:CMD_KEY]) {
        [_cmdMenu setState:1];
    }
    if ([flags containsObject:CTRL_KEY]) {
        [_ctrlMenu setState:1];
    }
    if ([flags containsObject:SHIFT_KEY]) {
        [_shiftMenu setState:1];
    }
    if ([EMRPreferences useMouseMove]) {
        [_useMouseMoveMenu setState: 1];
    }
}

- (IBAction)modifierToggle:(id)sender {
    NSMenuItem *menu = (NSMenuItem*)sender;
    NSInteger newState = ![menu state];
    [menu setState:newState];
    [EMRPreferences setModifierKey:[menu title] enabled:newState];
    keyModifierFlags = [EMRPreferences modifierFlags];
}

- (IBAction)useMouseMoveToggle:(id)sender {
    NSMenuItem *menu = (NSMenuItem*)sender;
    NSInteger newState = ![menu state];
    [menu setState:newState];
    [EMRPreferences setUseMouseMove: newState];
}

- (IBAction)resetModifiersToDefaults:(id)sender {
    [EMRPreferences removeDefaults];
    [self initModifierMenuItems];
    keyModifierFlags = [EMRPreferences modifierFlags];
}

- (IBAction)toggleDisabled:(id)sender {
    EMRMoveResize* moveResize = [EMRMoveResize instance];
    if ([_disabledMenu state] == 0) {
        // We are enabled. Disable...
        [_disabledMenu setState:1];
        [self setMenusEnabled:0];
        [self disableRunLoopSource:moveResize];
    }
    else {
        // We are disabled. Enable.
        [_disabledMenu setState:0];
        [self setMenusEnabled:1];
        [self enableRunLoopSource:moveResize];
    }
}

- (int)modifierFlags {
    return keyModifierFlags;
}

- (BOOL)useMouseMove {
    return [_useMouseMoveMenu state];
}

- (void)setMenusEnabled:(NSInteger)enabled {
    [_altMenu setEnabled:enabled];
    [_cmdMenu setEnabled:enabled];
    [_ctrlMenu setEnabled:enabled];
    [_shiftMenu setEnabled:enabled];
}

@end
