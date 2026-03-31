/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * On-screen keyboard, toolbar, and hardware keyboard (pressesBegan/Ended)
 * handling for GHOSTUIWindow. Extracted from GHOST_WindowIOS.mm as a category.
 */

#include "GHOST_WindowIOS_Internal.h"

#include "GHOST_Debug.hh"
#include "GHOST_EventKey.hh"

#include <memory>

// #define IOS_INPUT_LOGGING
#if defined(IOS_INPUT_LOGGING)
#  define IOS_INPUT_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_INPUT_LOG(...)
#endif

#pragma mark - On-Screen Keyboard

@implementation GHOSTUIWindow (Keyboard)

- (void)initToolbar
{
  /* This gets the current view size */
  UIView *ui_view = window->getView();
  CGSize frame_size = [ui_view sizeThatFits:CGSizeMake(0.0f, 0.0f)];
  /* Create a toolbar the width of the screen. */
  toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, frame_size.width, 44)];
  toolbar.barStyle = UIBarStyleDefault;
  toolbar.translucent = true;
  /* Despite following Apple guidelines this toolbar still
   * appears to violate the view constraints. It displays fine
   * but generates warning output to the console. */
  toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  toolbar.translatesAutoresizingMaskIntoConstraints = NO;
  [toolbar sizeToFit];

  toolbar_tip_item = [[UIBarButtonItem alloc] initWithTitle:@""
                                                      style:UIBarButtonItemStylePlain
                                                     target:nil
                                                     action:nil];

  toolbar_live_text_item = [[UIBarButtonItem alloc] initWithTitle:@""
                                                            style:UIBarButtonItemStylePlain
                                                           target:nil
                                                           action:nil];

  toolbar_done_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:nil
                           action:@selector(handleDoneButton)];

  toolbar_cancel_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                           target:nil
                           action:@selector(handleCancelButton)];

  /* Prevents editing of tip and live text fields. */
  toolbar_tip_item.enabled = NO;
  toolbar_live_text_item.enabled = NO;
  toolbar_live_text_item.tintColor = UIColor.blackColor;

  /* Set the live text to a fixed width. */
  /* TODO: set toolbar_live_text_item.width dynamically? Need to move out of init if so. */
  toolbar_live_text_item.width = 150.0f;

  toolbar.items = @[
    toolbar_tip_item,
    toolbar_live_text_item,
    toolbar_done_editing_item,
    toolbar_cancel_editing_item
  ];
}

- (void)generateKeyboardReturnEvent
{
  /*
   Only push the event back if the keyboard is active otherwise we may generate new
   spurious events.
   */
  if (onscreen_keyboard_active) {
    /*
     This event should cause ui_textedit_end() to be called which will
     hide the keyboard.
     */
    system->pushEvent(std::make_unique<GHOST_EventKey>(system->getMilliSeconds(),
                                         GHOST_kEventKeyDown,
                                         window,
                                         GHOST_kKeyEnter,
                                         false,
                                         nullptr));
  }
  else {
    IOS_INPUT_LOG(@"Ignoring handleKeyboardReturn %@", text_field.text);
  }
}

- (void)handleKeyboardReturn:(UITextField *)tf
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"handleKeyboardReturn %@", tf.text);
    [self generateKeyboardReturnEvent];
  }
}

- (void)handleKeyboardEditChange:(UITextField *)tf
{
  @synchronized(self) {

    /* Update the text in the tool bar as the edits arrive. */
    if (toolbar_live_text_item) {
      toolbar_live_text_item.title = tf.text;
      /* Force toolbar to update */
      [toolbar setNeedsLayout];
      [toolbar layoutIfNeeded];
    }
    IOS_INPUT_LOG(@"Keyboard Edit change detected %@", tf.text);
  }
}

- (void)handleKeyboardEditBegin:(UITextField *)tf
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard Edit begin detected %@", tf.text);
  }
}

- (void)handleKeyboardEditEnd:(UITextField *)tf
{
  @synchronized(self) {
    /*
     This can get called when the keyboard is minimised
     so send a return keypress to emulate effective end
     of editing. Otherwise Blender's focus will remain
     on the text field.
     */
    IOS_INPUT_LOG(@"Keyboard Edit end detected %@", tf.text);
    [self generateKeyboardReturnEvent];
  }
}

- (void)handleDoneButton
{
  IOS_INPUT_LOG(@"Keyboard Done button press detected %@", text_field.text);
  [self generateKeyboardReturnEvent];
}

- (void)handleCancelButton
{
  IOS_INPUT_LOG(@"Keyboard Cancel button press detected %@", text_field.text);
  /* Restore the original text and return */
  text_field.text = original_text;
  [self generateKeyboardReturnEvent];
}

/*
 * Add a text field so we can handle input from a popup keyboard and
 * attach it to our root window.
 */
- (void)initUITextField
{
  /* Initialise it if we have not already done so. */
  if (!text_field) {
    text_field = [[UITextField alloc] init];

    text_field.contentScaleFactor = window->getWindowScaleFactor();

    if (toolbar_enabled) {
      [self initToolbar];
      text_field.inputAccessoryView = toolbar;
    }

    [window->rootWindow addSubview:text_field];

    /* Add a handler for when 'return' is pressed on keyboard. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardReturn:)
         forControlEvents:UIControlEventEditingDidEndOnExit];

    /* Add a handler for when the text field changes. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditChange:)
         forControlEvents:UIControlEventEditingChanged];

    /* Add a handler for when user edits a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditBegin:)
         forControlEvents:UIControlEventEditingDidBegin];

    /* Add a handler for when user finishes editing a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditEnd:)
         forControlEvents:UIControlEventEditingDidEnd];
  }
}

- (void)convertWindowCoordToDisplayCoordWithWindow:(int)windowX
                                           windowY:(int)windowY
                                          displayX:(double *)displayX
                                          displayY:(double *)displayY
                                             flipY:(BOOL)flipY
{
  float pixelScale = window->getWindowScaleFactor();
  CGSize logicalWindowSize = window->getLogicalWindowSize();

  *displayX = (double)windowX / pixelScale;
  *displayY = (double)windowY / pixelScale;

  if (flipY) {
    *displayY = logicalWindowSize.height - *displayY;
  }
}

- (UITextField *)getUITextField
{
  return text_field;
}

- (void)setupKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  /* Initialise it if we have not already done so */
  if (!text_field) {
    [self initUITextField];
  }

  /* Save this set of keyboard properties */
  current_keyboard_properties = keyboard_properties;

  /* Convert the text box coords to display coords */
  CGRect displayRect;
  [self convertWindowCoordToDisplayCoordWithWindow:keyboard_properties.text_box_origin[0]
                                           windowY:keyboard_properties.text_box_origin[1]
                                          displayX:&displayRect.origin.x
                                          displayY:&displayRect.origin.y
                                             flipY:true];

  [self convertWindowCoordToDisplayCoordWithWindow:keyboard_properties.text_box_size[0]
                                           windowY:keyboard_properties.text_box_size[1]
                                          displayX:&displayRect.size.width
                                          displayY:&displayRect.size.height
                                             flipY:false];

  /* Where to display the text on-screen. */
  text_field.frame = displayRect;

  /* Initialise text with existing string. */
  text_field.text = keyboard_properties.text_string ?
                        [NSString stringWithUTF8String:keyboard_properties.text_string] :
                        @"";
  /* Take a copy of the string so we can restore it if neccessary */
  original_text = keyboard_properties.text_string ?
                      [NSString stringWithUTF8String:keyboard_properties.text_string] :
                      @"";

  /* Set keyboard type and text alignment.
   * NOTE - the keyboard type is only honoured if using an Apple
   * pencil or if the keyboard is floating.
   * Otherwise it will just be the default full screen type. */
  switch (keyboard_properties.keyboard_type) {
    case GHOST_KeyboardProperties::ascii_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeASCIICapable;
      text_field.textAlignment = NSTextAlignmentLeft;
      break;
    }
    case GHOST_KeyboardProperties::decimal_numpad_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeDecimalPad;
      text_field.textAlignment = NSTextAlignmentCenter;
      break;
    }
    case GHOST_KeyboardProperties::numpad_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeNumberPad;
      text_field.textAlignment = NSTextAlignmentCenter;
      break;
    }
    default: {
      text_field.keyboardType = UIKeyboardTypeDefault;
      text_field.textAlignment = NSTextAlignmentLeft;
    }
  }
  /* Reset keyboard type to default if not using Apple Pencil
   * or it's not floating. (Need to add floating detection.) */
  if (!last_tap_with_pencil) {
    // text_field.keyboardType = UIKeyboardTypeDefault;
  }

  /* Set light/dark mode or adopt system default. */
  text_field.keyboardAppearance = UIKeyboardAppearanceDefault;

  /* This seems sensible given Blender's typical behaviour. */
  text_field.autocorrectionType = UITextAutocorrectionTypeNo;
  text_field.spellCheckingType = UITextSpellCheckingTypeNo;

  /* Set font size. */
  float fontSize = keyboard_properties.font_size / window->getWindowScaleFactor();
  text_field.font = [UIFont systemFontOfSize:fontSize];

  /* Set font color. */
  text_field.textColor = [UIColor colorWithRed:keyboard_properties.font_color[0]
                                         green:keyboard_properties.font_color[1]
                                          blue:keyboard_properties.font_color[2]
                                         alpha:keyboard_properties.font_color[3]];

  /* Initial highlighting and text-cursor position. */
  switch (keyboard_properties.inital_text_state) {
    case GHOST_KeyboardProperties::select_all_text: {
      [text_field selectAll:nil];
      break;
    }
    case GHOST_KeyboardProperties::select_text_range: {
      UITextPosition *startPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[0]];
      UITextPosition *endPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[1]];
      text_field.selectedTextRange = [text_field textRangeFromPosition:startPosition
                                                            toPosition:endPosition];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_start: {
      UITextPosition *beginning = text_field.beginningOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:beginning
                                                            toPosition:beginning];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_end: {
      UITextPosition *end = text_field.endOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:end toPosition:end];
      break;
    }
    default: {
      GHOST_ASSERT(FALSE, "GHOST_SystemIOS::setupTextField unsupported text select option");
    }
  }

  /* Setup the tool bar if it's enabled. */
  if (toolbar_enabled) {
    toolbar_live_text_item.title = text_field.text;
    toolbar_tip_item.title = keyboard_properties.tip_text ?
                                 [NSString stringWithCString:keyboard_properties.tip_text
                                                    encoding:NSUTF8StringEncoding] :
                                 @"";
  }
}

- (void)externalKeyboardChange:(NSNotification *)notification
{
  external_keyboard_connected = [GCKeyboard coalescedKeyboard] != nil;
  IOS_INPUT_LOG(@"External Keyboard %s",
                external_keyboard_connected ? "Connected" : "Disconnected");
}

- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard popup request received %@", text_field.text);
    [self setupKeyboard:keyboard_properties];

    if (!onscreen_keyboard_active) {
      text_field.userInteractionEnabled = YES;
      if (![text_field becomeFirstResponder]) {
        GHOST_ASSERT(FALSE, "GHOST_SystemIOS::popupOnScreenKeyboard Failed to display keyboard");
      }
      onscreen_keyboard_active = true;
    }
  }
  return GHOST_kSuccess;
}

- (GHOST_TSuccess)hideOnscreenKeyboard
{
  /* Lock access around keyboard handling events. */
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard hide request received %@", text_field.text);

    if (onscreen_keyboard_active) {
      /*
       This must come first so that any of the keyboard event handlers that get
       triggered in response to shutting down the keyboard don't do anything
       (like generating events back to Blender)
       */
      onscreen_keyboard_active = false;

      /* Shut down the keyboard. */
      [text_field resignFirstResponder];
      /*
       Note: This may cause the console to display the warning message:
       "-[UIApplication _touchesEvent] will no longer work as expected. Please stop using it."
       But since this is being generated by Apple OS code there's nothing obvious to fix it right
       now.
       */

      IOS_INPUT_LOG(@"Resigned keyboard responder");
      /*
       This is required to disable any subsequent interactions with the text field that could
       potentially bypass Blender's input handling (since the UITextField is now live
       on the view)
       */
      text_field.userInteractionEnabled = NO;

      /* Save the input to an owned c-string copy. */
      free(text_field_string);
      text_field_string = text_field.text ? strdup([text_field.text UTF8String]) : NULL;

      /* Delete the text field copy of the string */
      text_field.text = nil;
    }
  }
  IOS_INPUT_LOG(@"Text field value was %s", text_field_string);
  return GHOST_kSuccess;
}

- (const char *)getLastKeyboardString
{
  /* Lock access around keyboard handling events */
  @synchronized(self) {

    /* Update text string if one exists */
    if (text_field.text && ![text_field.text isEqualToString:@""]) {
      /* Save the input to an owned c-string copy. */
      free(text_field_string);
      text_field_string = strdup([text_field.text UTF8String]);
    }
  }
  return text_field_string;
}

#pragma mark - Hardware Keyboard (pressesBegan / pressesEnded)

/**
 * Convert UIKeyboardHIDUsage (USB HID usage codes) to GHOST_TKey.
 * Reference: USB HID Usage Tables, Section 10 (Keyboard/Keypad Page 0x07).
 */
static GHOST_TKey convertHIDKeyToGhost(UIKeyboardHIDUsage keyCode)
    API_AVAILABLE(ios(13.4))
{
  switch (keyCode) {
    /* Letters (0x04-0x1D). */
    case UIKeyboardHIDUsageKeyboardA: return GHOST_kKeyA;
    case UIKeyboardHIDUsageKeyboardB: return GHOST_kKeyB;
    case UIKeyboardHIDUsageKeyboardC: return GHOST_kKeyC;
    case UIKeyboardHIDUsageKeyboardD: return GHOST_kKeyD;
    case UIKeyboardHIDUsageKeyboardE: return GHOST_kKeyE;
    case UIKeyboardHIDUsageKeyboardF: return GHOST_kKeyF;
    case UIKeyboardHIDUsageKeyboardG: return GHOST_kKeyG;
    case UIKeyboardHIDUsageKeyboardH: return GHOST_kKeyH;
    case UIKeyboardHIDUsageKeyboardI: return GHOST_kKeyI;
    case UIKeyboardHIDUsageKeyboardJ: return GHOST_kKeyJ;
    case UIKeyboardHIDUsageKeyboardK: return GHOST_kKeyK;
    case UIKeyboardHIDUsageKeyboardL: return GHOST_kKeyL;
    case UIKeyboardHIDUsageKeyboardM: return GHOST_kKeyM;
    case UIKeyboardHIDUsageKeyboardN: return GHOST_kKeyN;
    case UIKeyboardHIDUsageKeyboardO: return GHOST_kKeyO;
    case UIKeyboardHIDUsageKeyboardP: return GHOST_kKeyP;
    case UIKeyboardHIDUsageKeyboardQ: return GHOST_kKeyQ;
    case UIKeyboardHIDUsageKeyboardR: return GHOST_kKeyR;
    case UIKeyboardHIDUsageKeyboardS: return GHOST_kKeyS;
    case UIKeyboardHIDUsageKeyboardT: return GHOST_kKeyT;
    case UIKeyboardHIDUsageKeyboardU: return GHOST_kKeyU;
    case UIKeyboardHIDUsageKeyboardV: return GHOST_kKeyV;
    case UIKeyboardHIDUsageKeyboardW: return GHOST_kKeyW;
    case UIKeyboardHIDUsageKeyboardX: return GHOST_kKeyX;
    case UIKeyboardHIDUsageKeyboardY: return GHOST_kKeyY;
    case UIKeyboardHIDUsageKeyboardZ: return GHOST_kKeyZ;

    /* Number row (0x1E-0x27). */
    case UIKeyboardHIDUsageKeyboard1: return GHOST_kKey1;
    case UIKeyboardHIDUsageKeyboard2: return GHOST_kKey2;
    case UIKeyboardHIDUsageKeyboard3: return GHOST_kKey3;
    case UIKeyboardHIDUsageKeyboard4: return GHOST_kKey4;
    case UIKeyboardHIDUsageKeyboard5: return GHOST_kKey5;
    case UIKeyboardHIDUsageKeyboard6: return GHOST_kKey6;
    case UIKeyboardHIDUsageKeyboard7: return GHOST_kKey7;
    case UIKeyboardHIDUsageKeyboard8: return GHOST_kKey8;
    case UIKeyboardHIDUsageKeyboard9: return GHOST_kKey9;
    case UIKeyboardHIDUsageKeyboard0: return GHOST_kKey0;

    /* Control keys. */
    case UIKeyboardHIDUsageKeyboardReturnOrEnter: return GHOST_kKeyEnter;
    case UIKeyboardHIDUsageKeyboardEscape: return GHOST_kKeyEsc;
    case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return GHOST_kKeyBackSpace;
    case UIKeyboardHIDUsageKeyboardTab: return GHOST_kKeyTab;
    case UIKeyboardHIDUsageKeyboardSpacebar: return GHOST_kKeySpace;
    case UIKeyboardHIDUsageKeyboardDeleteForward: return GHOST_kKeyDelete;

    /* Punctuation. */
    case UIKeyboardHIDUsageKeyboardHyphen: return GHOST_kKeyMinus;
    case UIKeyboardHIDUsageKeyboardEqualSign: return GHOST_kKeyEqual;
    case UIKeyboardHIDUsageKeyboardOpenBracket: return GHOST_kKeyLeftBracket;
    case UIKeyboardHIDUsageKeyboardCloseBracket: return GHOST_kKeyRightBracket;
    case UIKeyboardHIDUsageKeyboardBackslash: return GHOST_kKeyBackslash;
    case UIKeyboardHIDUsageKeyboardSemicolon: return GHOST_kKeySemicolon;
    case UIKeyboardHIDUsageKeyboardQuote: return GHOST_kKeyQuote;
    case UIKeyboardHIDUsageKeyboardGraveAccentAndTilde: return GHOST_kKeyAccentGrave;
    case UIKeyboardHIDUsageKeyboardComma: return GHOST_kKeyComma;
    case UIKeyboardHIDUsageKeyboardPeriod: return GHOST_kKeyPeriod;
    case UIKeyboardHIDUsageKeyboardSlash: return GHOST_kKeySlash;

    /* Navigation. */
    case UIKeyboardHIDUsageKeyboardUpArrow: return GHOST_kKeyUpArrow;
    case UIKeyboardHIDUsageKeyboardDownArrow: return GHOST_kKeyDownArrow;
    case UIKeyboardHIDUsageKeyboardLeftArrow: return GHOST_kKeyLeftArrow;
    case UIKeyboardHIDUsageKeyboardRightArrow: return GHOST_kKeyRightArrow;
    case UIKeyboardHIDUsageKeyboardHome: return GHOST_kKeyHome;
    case UIKeyboardHIDUsageKeyboardEnd: return GHOST_kKeyEnd;
    case UIKeyboardHIDUsageKeyboardPageUp: return GHOST_kKeyUpPage;
    case UIKeyboardHIDUsageKeyboardPageDown: return GHOST_kKeyDownPage;

    /* Function keys. */
    case UIKeyboardHIDUsageKeyboardF1: return GHOST_kKeyF1;
    case UIKeyboardHIDUsageKeyboardF2: return GHOST_kKeyF2;
    case UIKeyboardHIDUsageKeyboardF3: return GHOST_kKeyF3;
    case UIKeyboardHIDUsageKeyboardF4: return GHOST_kKeyF4;
    case UIKeyboardHIDUsageKeyboardF5: return GHOST_kKeyF5;
    case UIKeyboardHIDUsageKeyboardF6: return GHOST_kKeyF6;
    case UIKeyboardHIDUsageKeyboardF7: return GHOST_kKeyF7;
    case UIKeyboardHIDUsageKeyboardF8: return GHOST_kKeyF8;
    case UIKeyboardHIDUsageKeyboardF9: return GHOST_kKeyF9;
    case UIKeyboardHIDUsageKeyboardF10: return GHOST_kKeyF10;
    case UIKeyboardHIDUsageKeyboardF11: return GHOST_kKeyF11;
    case UIKeyboardHIDUsageKeyboardF12: return GHOST_kKeyF12;

    /* Numpad. */
    case UIKeyboardHIDUsageKeypad0: return GHOST_kKeyNumpad0;
    case UIKeyboardHIDUsageKeypad1: return GHOST_kKeyNumpad1;
    case UIKeyboardHIDUsageKeypad2: return GHOST_kKeyNumpad2;
    case UIKeyboardHIDUsageKeypad3: return GHOST_kKeyNumpad3;
    case UIKeyboardHIDUsageKeypad4: return GHOST_kKeyNumpad4;
    case UIKeyboardHIDUsageKeypad5: return GHOST_kKeyNumpad5;
    case UIKeyboardHIDUsageKeypad6: return GHOST_kKeyNumpad6;
    case UIKeyboardHIDUsageKeypad7: return GHOST_kKeyNumpad7;
    case UIKeyboardHIDUsageKeypad8: return GHOST_kKeyNumpad8;
    case UIKeyboardHIDUsageKeypad9: return GHOST_kKeyNumpad9;
    case UIKeyboardHIDUsageKeypadPeriod: return GHOST_kKeyNumpadPeriod;
    case UIKeyboardHIDUsageKeypadPlus: return GHOST_kKeyNumpadPlus;
    case UIKeyboardHIDUsageKeypadHyphen: return GHOST_kKeyNumpadMinus;
    case UIKeyboardHIDUsageKeypadAsterisk: return GHOST_kKeyNumpadAsterisk;
    case UIKeyboardHIDUsageKeypadSlash: return GHOST_kKeyNumpadSlash;
    case UIKeyboardHIDUsageKeypadEnter: return GHOST_kKeyNumpadEnter;

    /* Modifier keys (handled separately but map them for completeness). */
    case UIKeyboardHIDUsageKeyboardLeftControl: return GHOST_kKeyLeftControl;
    case UIKeyboardHIDUsageKeyboardLeftShift: return GHOST_kKeyLeftShift;
    case UIKeyboardHIDUsageKeyboardLeftAlt: return GHOST_kKeyLeftAlt;
    case UIKeyboardHIDUsageKeyboardLeftGUI: return GHOST_kKeyLeftOS;
    case UIKeyboardHIDUsageKeyboardRightControl: return GHOST_kKeyRightControl;
    case UIKeyboardHIDUsageKeyboardRightShift: return GHOST_kKeyRightShift;
    case UIKeyboardHIDUsageKeyboardRightAlt: return GHOST_kKeyRightAlt;
    case UIKeyboardHIDUsageKeyboardRightGUI: return GHOST_kKeyRightOS;
    case UIKeyboardHIDUsageKeyboardCapsLock: return GHOST_kKeyCapsLock;

    default:
      return GHOST_kKeyUnknown;
  }
}

/** Check if a HID usage code is a modifier key. */
static bool isModifierKey(UIKeyboardHIDUsage keyCode) API_AVAILABLE(ios(13.4))
{
  switch (keyCode) {
    case UIKeyboardHIDUsageKeyboardLeftControl:
    case UIKeyboardHIDUsageKeyboardLeftShift:
    case UIKeyboardHIDUsageKeyboardLeftAlt:
    case UIKeyboardHIDUsageKeyboardLeftGUI:
    case UIKeyboardHIDUsageKeyboardRightControl:
    case UIKeyboardHIDUsageKeyboardRightShift:
    case UIKeyboardHIDUsageKeyboardRightAlt:
    case UIKeyboardHIDUsageKeyboardRightGUI:
    case UIKeyboardHIDUsageKeyboardCapsLock:
      return true;
    default:
      return false;
  }
}

/** Map a GHOST_TKey modifier to GHOST_TModifierKey, or -1 if not a modifier. */
static int ghostKeyToModifier(GHOST_TKey key)
{
  switch (key) {
    case GHOST_kKeyLeftShift: return GHOST_kModifierKeyLeftShift;
    case GHOST_kKeyRightShift: return GHOST_kModifierKeyRightShift;
    case GHOST_kKeyLeftAlt: return GHOST_kModifierKeyLeftAlt;
    case GHOST_kKeyRightAlt: return GHOST_kModifierKeyRightAlt;
    case GHOST_kKeyLeftControl: return GHOST_kModifierKeyLeftControl;
    case GHOST_kKeyRightControl: return GHOST_kModifierKeyRightControl;
    case GHOST_kKeyLeftOS: return GHOST_kModifierKeyLeftOS;
    case GHOST_kKeyRightOS: return GHOST_kModifierKeyRightOS;
    default: return -1;
  }
}

- (BOOL)canBecomeFirstResponder
{
  return YES;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  if (@available(iOS 13.4, *)) {
    bool handled = false;
    for (UIPress *press in presses) {
      if (!press.key) {
        continue;
      }

      UIKeyboardHIDUsage keyCode = press.key.keyCode;
      GHOST_TKey ghostKey = convertHIDKeyToGhost(keyCode);
      if (ghostKey == GHOST_kKeyUnknown) {
        continue;
      }

      /* Extract UTF-8 characters for text input. */
      char utf8_buf[6] = {0};
      NSString *chars = press.key.characters;
      if (chars.length > 0 && !isModifierKey(keyCode)) {
        const char *c = [chars UTF8String];
        if (c) {
          size_t len = strlen(c);
          if (len > 0 && len < sizeof(utf8_buf)) {
            memcpy(utf8_buf, c, len);
          }
        }
      }

      /* Update modifier state tracking. */
      int mod = ghostKeyToModifier(ghostKey);
      if (mod >= 0) {
        system->setModifierKey((GHOST_TModifierKey)mod, true);
      }

      system->pushEvent(std::make_unique<GHOST_EventKey>(
          system->getMilliSeconds(),
          GHOST_kEventKeyDown,
          window,
          ghostKey,
          false,
          utf8_buf));
      system->notifyExternalEventProcessed();
      handled = true;
    }

    if (!handled) {
      [super pressesBegan:presses withEvent:event];
    }
  }
  else {
    [super pressesBegan:presses withEvent:event];
  }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  if (@available(iOS 13.4, *)) {
    bool handled = false;
    for (UIPress *press in presses) {
      if (!press.key) {
        continue;
      }

      GHOST_TKey ghostKey = convertHIDKeyToGhost(press.key.keyCode);
      if (ghostKey == GHOST_kKeyUnknown) {
        continue;
      }

      /* Update modifier state tracking. */
      int mod = ghostKeyToModifier(ghostKey);
      if (mod >= 0) {
        system->setModifierKey((GHOST_TModifierKey)mod, false);
      }

      system->pushEvent(std::make_unique<GHOST_EventKey>(
          system->getMilliSeconds(),
          GHOST_kEventKeyUp,
          window,
          ghostKey,
          false));
      system->notifyExternalEventProcessed();
      handled = true;
    }

    if (!handled) {
      [super pressesEnded:presses withEvent:event];
    }
  }
  else {
    [super pressesEnded:presses withEvent:event];
  }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  /* Treat cancelled as key-up to avoid stuck keys. */
  [self pressesEnded:presses withEvent:event];
}

@end
