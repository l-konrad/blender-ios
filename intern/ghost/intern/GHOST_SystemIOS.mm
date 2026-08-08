/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "GHOST_SystemIOS.hh"

#include "GHOST_ContextIOS.hh"
#include "GHOST_WindowIOS.hh"

#include "GHOST_Debug.hh"
#include "GHOST_EventButton.hh"
#include "GHOST_EventCursor.hh"
#include "GHOST_EventDragnDrop.hh"
#include "GHOST_EventString.hh"
#include "GHOST_WindowManager.hh"

#include <memory>

#ifdef WITH_INPUT_NDOF
#  include "GHOST_NDOFManagerCocoa.hh"
#endif

#import <MetalKit/MTKView.h>
#import <UIKit/UIKit.h>

#include <time.h>
#include <os/proc.h>

#include "GHOST_FilePickerIOS.hh"

// #define IOS_SYSTEM_LOGGING
#if defined(IOS_SYSTEM_LOGGING)
#  define IOS_SYSTEM_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_SYSTEM_LOG(...)
#endif

#pragma mark -

namespace blender {
struct bContext;
}
static blender::bContext *C = nullptr;

int argc = 0;
const char **argv = nullptr;

/* Implemented in wm.cc (inside namespace blender). */
namespace blender {
void WM_main_loop_body(bContext *C);
}
int main_ios_callback(int argc, const char **argv);

/* C-linkage bridge to windowmanager — avoids fragile dlsym with mangled names.
 * See source/blender/windowmanager/wm_ios_bridge.h for declarations. */
#include "../../../../source/blender/windowmanager/wm_ios_bridge.h"

@interface IOSAppDelegate : UIResponder <UIApplicationDelegate>

@property(strong, nonatomic) UIWindow *window;

@end

@implementation IOSAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  main_ios_callback(argc, argv);

  return YES;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());

  system->handleOpenDocumentRequest(url.path);

  return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
  if (!C) {
    return;
  }

  /* Request extra time from iOS to complete the save. */
  __block UIBackgroundTaskIdentifier bgTask = [application
      beginBackgroundTaskWithName:@"BlenderAutosave"
               expirationHandler:^{
                 [application endBackgroundTask:bgTask];
                 bgTask = UIBackgroundTaskInvalid;
               }];

  NSLog(@"Blender: entering background, saving autosave...");
  WM_ios_autosave((void *)C);
  WM_ios_autosave_timer_end((void *)C);

  [application endBackgroundTask:bgTask];
  bgTask = UIBackgroundTaskInvalid;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
  if (!C) {
    return;
  }

  WM_ios_autosave_timer_begin((void *)C);
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  if (!C) {
    return;
  }

  NSLog(@"Blender: app terminating, saving autosave...");
  WM_ios_autosave((void *)C);
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
  size_t available = 0;
  if (@available(iOS 13.0, *)) {
    available = (size_t)os_proc_available_memory();
  }

  NSLog(@"Blender: iOS memory warning! Available: %.0f MB",
        (double)available / (1024.0 * 1024.0));

  /* Force an autosave in case iOS kills us next. */
  if (C) {
    WM_ios_autosave((void *)C);
  }

  /* Free GPU caches and trim undo history. */
  if (C) {
    WM_ios_reduce_memory((void *)C);
  }
}

@end

@implementation GHOST_IOSMetalRenderer
{
  id<MTLDevice> _device;
  id<MTLCommandQueue> _commandQueue;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
  self = [super init];
  if (self) {
    _device = mtkView.device;

    /* Create the command queue. */
    _commandQueue = [_device newCommandQueue];
  }

  return self;
}

- (void)drawInMTKView:(nonnull MTKView *)MTKView
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());

  /* We should always have a window... */
  if (system->current_active_window) {

    /* If the current window has some outstanding swaps we need to
     * service them before handing control back to Blender otherwise
     * they may go missing. */
    if (system->current_active_window->deferred_swap_buffers_count) {
      IOS_SYSTEM_LOG(@"Issuing oustanding swaps");
      system->current_active_window->flushDeferredSwapBuffers();
      /* Make sure we get another call to draw. */
      system->current_active_window->needsDisplayUpdate();
      return;
    }

    system->current_active_window->beginFrame();
  }

  /* Run the main loop to handle all events. */
  if (C) {
    blender::WM_main_loop_body(C);
  }

  if (system->current_active_window) {
    system->current_active_window->flushDeferredSwapBuffers();
    system->current_active_window->endFrame();
  }

  /* Was there a request to switch windows? */
  if (system->next_active_window != nullptr) {
    if (system->current_active_window) {
      system->current_active_window->resignKeyWindow();
    }
    system->next_active_window->makeKeyWindow();
    system->next_active_window = nullptr;
  }
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (!system->current_active_window) {
    return;
  }

  system->pushEvent(std::make_unique<GHOST_Event>(
      system->getMilliSeconds(), GHOST_kEventWindowSize, system->current_active_window));
}

@end

int GHOST_iosmain(int _argc, const char **_argv)
{
  argc = _argc;
  argv = _argv;
  @autoreleasepool {
    return UIApplicationMain(
        _argc, (char *_Nullable *)_argv, nil, NSStringFromClass([IOSAppDelegate class]));
  }
}

void GHOST_iosfinalize(blender::bContext *CTX)
{
  C = CTX;
}

#pragma mark Utility functions

/* convertKey / convertButton removed – superseded by convertHIDKeyToGhost()
 * in GHOST_WindowIOS.mm which maps UIKeyboardHIDUsage codes directly. */

#pragma mark Utility functions

#define FIRSTFILEBUFLG 512
static bool g_hasFirstFile = false;
static char g_firstFileBuf[512];

extern "C" int GHOST_HACK_getFirstFile(char buf[FIRSTFILEBUFLG])
{
  if (g_hasFirstFile) {
    strncpy(buf, g_firstFileBuf, FIRSTFILEBUFLG - 1);
    buf[FIRSTFILEBUFLG - 1] = '\0';
    return 1;
  }
  else {
    return 0;
  }
}

#pragma mark initialization/finalization

GHOST_SystemIOS::GHOST_SystemIOS()
{
  m_modifierMask = 0;
  m_outsideLoopEventProcessed = false;
  m_needDelayedApplicationBecomeActiveEventProcessing = false;

  /* Use monotonic clock for a stable time base. */
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  m_start_time = ((uint64_t)ts.tv_sec * 1000) + ((uint64_t)ts.tv_nsec / 1000000);

  m_ignoreWindowSizedMessages = false;
  m_ignoreMomentumScroll = false;
  m_multiTouchScroll = false;
  m_last_warp_timestamp = 0;
}

GHOST_SystemIOS::~GHOST_SystemIOS() {}

GHOST_TSuccess GHOST_SystemIOS::init()
{
  GHOST_TSuccess success = GHOST_System::init();
  if (success) {

#ifdef WITH_INPUT_NDOF
    m_ndofManager = new GHOST_NDOFManagerCocoa(*this);
#endif
  }
  return success;
}

#pragma mark window management

uint64_t GHOST_SystemIOS::getMilliSeconds() const
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  uint64_t now = ((uint64_t)ts.tv_sec * 1000) + ((uint64_t)ts.tv_nsec / 1000000);
  return now - m_start_time;
}

uint8_t GHOST_SystemIOS::getNumDisplays() const
{
  return 1;
}

void GHOST_SystemIOS::getMainDisplayDimensions(uint32_t &width, uint32_t &height) const
{
  /* Use the window scene's screen instead of deprecated [UIScreen mainScreen]. */
  UIWindow *keyWindow = nil;
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      UIWindowScene *windowScene = (UIWindowScene *)scene;
      for (UIWindow *w in windowScene.windows) {
        if (w.isKeyWindow) {
          keyWindow = w;
          break;
        }
      }
      if (keyWindow) break;
    }
  }
  UIScreen *screen = keyWindow.windowScene.screen ?: [UIScreen mainScreen];
  CGRect screenRect = screen.bounds;
  CGFloat scaling_fac = screen.scale;
  CGFloat screenWidth = screenRect.size.width * scaling_fac;
  CGFloat screenHeight = screenRect.size.height * scaling_fac;

  if (screenWidth <= 0 || screenHeight <= 0) {
    GHOST_ASSERT(false, "Negative or null display dimensions");
    screenWidth = 2732;
    screenHeight = 2048;
  }

  width = screenWidth;
  height = screenHeight;
}

void GHOST_SystemIOS::getAllDisplayDimensions(uint32_t &width, uint32_t &height) const
{
  /* TODO: iOS passthrough. */
  getMainDisplayDimensions(width, height);
}

GHOST_IWindow *GHOST_SystemIOS::createWindow(const char *title,
                                             int32_t /*left*/,
                                             int32_t /*top*/,
                                             uint32_t /*width*/,
                                             uint32_t /*height*/,
                                             GHOST_TWindowState state,
                                             GHOST_GPUSettings gpuSettings,
                                             const bool /*exclusive*/,
                                             const bool is_dialog,
                                             const GHOST_IWindow *parentWindow)
{
  const GHOST_ContextParams context_params = GHOST_CONTEXT_PARAMS_FROM_GPU_SETTINGS(gpuSettings);
  GHOST_IWindow *window = NULL;
  @autoreleasepool {

    /* Create window at native size from the active window scene. */
    CGRect bounds = CGRectMake(0, 0, 1024, 768);
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (@available(iOS 26.0, *)) {
          bounds = windowScene.effectiveGeometry.coordinateSpace.bounds;
        }
        else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
          bounds = windowScene.coordinateSpace.bounds;
#pragma clang diagnostic pop
        }
        break;
      }
    }

    window = (GHOST_IWindow *)new GHOST_WindowIOS(this,
                                                  title,
                                                  (int)bounds.origin.x,
                                                  (int)bounds.origin.y,
                                                  (unsigned int)bounds.size.width,
                                                  (unsigned int)bounds.size.height,
                                                  state,
                                                  gpuSettings.context_type,
                                                  context_params,
                                                  gpuSettings.flags & GHOST_gpuDebugContext,
                                                  is_dialog,
                                                  (GHOST_WindowIOS *)parentWindow);

    if (window->getValid()) {
      // Store the pointer to the window
      GHOST_ASSERT(window_manager_, "window_manager_ not initialized");
      window_manager_->addWindow(window);
      window_manager_->setActiveWindow(window);
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowActivate, window));
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowSize, window));
    }
    else {
      GHOST_PRINT("GHOST_SystemIOS::createWindow(): window invalid\n");
      delete window;
      window = NULL;
    }
  }
  return window;
}

/**
 * Create a new offscreen context.
 * Never explicitly delete the context, use #disposeContext() instead.
 * \return The new context (or 0 if creation failed).
 */
GHOST_IContext *GHOST_SystemIOS::createOffscreenContext(GHOST_GPUSettings /*gpuSettings*/)
{
  GHOST_Context *context = new GHOST_ContextIOS(GHOST_ContextParams(GHOST_CONTEXT_PARAMS_NONE), NULL, NULL);
  if (context->initializeDrawingContext())
    return context;
  else
    delete context;

  return NULL;
}

/**
 * Dispose of a context.
 * \param context: Pointer to the context to be disposed.
 * \return Indication of success.
 */
GHOST_TSuccess GHOST_SystemIOS::disposeContext(GHOST_IContext *context)
{
  delete context;

  return GHOST_kSuccess;
}

/**
 * \note : returns 0,0 on ios as no cursor is present.
 * TODO: If external mouse or trackpad is connected, we can query cursor position.
 */
GHOST_TSuccess GHOST_SystemIOS::getCursorPosition(int32_t & /*x*/, int32_t & /*y*/) const
{
  /* iOS Passthrough. */
  GHOST_IWindow *window = this->window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;
  // GHOST_ASSERT(FALSE,"GHOST_SystemIOS::getCursorPosition unsupported on iOS");
  return GHOST_kSuccess;
}

/**
 * \note : expect Cocoa screen coordinates
 * TODO: If external mouse or trackpad is connected, we can set cursor position.
 */
GHOST_TSuccess GHOST_SystemIOS::setCursorPosition(int32_t x, int32_t y)
{
  GHOST_WindowIOS *window = (GHOST_WindowIOS *)window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;

  pushEvent(std::make_unique<GHOST_EventCursor>(
      getMilliSeconds(), GHOST_kEventCursorMove, window, x, y, window->getTabletData()));
  m_outsideLoopEventProcessed = true;

  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::setMouseCursorPosition(int32_t /*x*/, int32_t /*y*/)
{
  /* iOS Passthrough. */
  GHOST_WindowIOS *window = (GHOST_WindowIOS *)window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;
  GHOST_ASSERT(FALSE, "GHOST_SystemIOS::setMouseCursorPosition unsupported on iOS");
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::getModifierKeys(GHOST_ModifierKeys &keys) const
{
  keys.set(GHOST_kModifierKeyLeftShift, (m_modifierMask & (1 << GHOST_kModifierKeyLeftShift)) != 0);
  keys.set(GHOST_kModifierKeyRightShift, (m_modifierMask & (1 << GHOST_kModifierKeyRightShift)) != 0);
  keys.set(GHOST_kModifierKeyLeftAlt, (m_modifierMask & (1 << GHOST_kModifierKeyLeftAlt)) != 0);
  keys.set(GHOST_kModifierKeyRightAlt, (m_modifierMask & (1 << GHOST_kModifierKeyRightAlt)) != 0);
  keys.set(GHOST_kModifierKeyLeftControl, (m_modifierMask & (1 << GHOST_kModifierKeyLeftControl)) != 0);
  keys.set(GHOST_kModifierKeyRightControl, (m_modifierMask & (1 << GHOST_kModifierKeyRightControl)) != 0);
  keys.set(GHOST_kModifierKeyLeftOS, (m_modifierMask & (1 << GHOST_kModifierKeyLeftOS)) != 0);
  keys.set(GHOST_kModifierKeyRightOS, (m_modifierMask & (1 << GHOST_kModifierKeyRightOS)) != 0);
  return GHOST_kSuccess;
}

void GHOST_SystemIOS::setModifierKey(GHOST_TModifierKey modifier, bool down)
{
  if (down) {
    m_modifierMask |= (1 << modifier);
  }
  else {
    m_modifierMask &= ~(1 << modifier);
  }
}

GHOST_TSuccess GHOST_SystemIOS::getButtons(GHOST_Buttons & /*buttons*/) const
{
  /* iOS Passthrough. */
  return GHOST_kSuccess;
}
GHOST_TCapabilityFlag GHOST_SystemIOS::getCapabilities() const
{
  return GHOST_TCapabilityFlag(GHOST_kCapabilityGPUReadFrontBuffer |
                               GHOST_kCapabilityNativeFileDialog);
}

#pragma mark Event handlers

/**
 * The event queue polling function
 */
bool GHOST_SystemIOS::processEvents(bool /*waitForEvent*/)
{
  /*
   Touch screen events are being processed through the UIView interactions
   We may need some additional code here to handle key presses if an external keybaord
   is attached
   */
  return true;
}

GHOST_TSuccess GHOST_SystemIOS::handleApplicationBecomeActiveEvent()
{
  m_modifierMask = 0;

  m_outsideLoopEventProcessed = true;
  return GHOST_kSuccess;
}

bool GHOST_SystemIOS::hasDialogWindow()
{
  for (GHOST_IWindow *iwindow : window_manager_->getWindows()) {
    GHOST_WindowIOS *window = (GHOST_WindowIOS *)iwindow;
    if (window->isDialog()) {
      return true;
    }
  }
  return false;
}

void GHOST_SystemIOS::notifyExternalEventProcessed()
{
  m_outsideLoopEventProcessed = true;
}

GHOST_TSuccess GHOST_SystemIOS::handleWindowEvent(GHOST_TEventType eventType,
                                                  GHOST_WindowIOS *window)
{
  if (!validWindow(window)) {
    return GHOST_kFailure;
  }
  switch (eventType) {
    case GHOST_kEventWindowClose:
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowClose, window));
      break;
    case GHOST_kEventWindowActivate:
      window_manager_->setActiveWindow(window);
      window->loadCursor(window->getCursorVisibility(), window->getCursorShape());
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowActivate, window));
      break;
    case GHOST_kEventWindowDeactivate:
      window_manager_->setWindowInactive(window);
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowDeactivate, window));
      break;
    case GHOST_kEventWindowUpdate:
      if (native_pixel_) {
        window->setNativePixelSize();
        pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventNativeResolutionChange, window));
      }
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowUpdate, window));
      break;
    case GHOST_kEventWindowMove:
      pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowMove, window));
      break;
    case GHOST_kEventWindowSize:
      if (!m_ignoreWindowSizedMessages) {
        // Enforce only one resize message per event loop
        // (coalescing all the live resize messages)
        window->updateDrawingContext();
        pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventWindowSize, window));
        // Mouse up event is trapped by the resizing event loop,
        // so send it anyway to the window manager.
        pushEvent(std::make_unique<GHOST_EventButton>(getMilliSeconds(),
                                        GHOST_kEventButtonUp,
                                        window,
                                        GHOST_kButtonMaskLeft,
                                        GHOST_TABLET_DATA_NONE));
      }
      break;
    case GHOST_kEventNativeResolutionChange:

      if (native_pixel_) {
        pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventNativeResolutionChange, window));
      }
      break;

    default:
      return GHOST_kFailure;
      break;
  }

  m_outsideLoopEventProcessed = true;

  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::popupOnScreenKeyboard(
    GHOST_IWindow *window, const GHOST_KeyboardProperties &keyboard_properties)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }
  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;
  return windowIOS->popupOnscreenKeyboard(keyboard_properties);
}

GHOST_TSuccess GHOST_SystemIOS::hideOnScreenKeyboard(GHOST_IWindow *window)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }

  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;

  return windowIOS->hideOnscreenKeyboard();
}

const char *GHOST_SystemIOS::getKeyboardInput(GHOST_IWindow *window)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return nullptr;
  }

  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;

  return windowIOS->getLastKeyboardString();
}

/* showNativeFileDialog, startSecurityScopedFileAccess, stopSecurityScopedFileAccess
 * are implemented in GHOST_FilePickerIOS.mm. */

// Note: called from NSWindow subclass
GHOST_TSuccess GHOST_SystemIOS::handleDraggingEvent(GHOST_TEventType eventType,
                                                    GHOST_TDragnDropTypes draggedObjectType,
                                                    GHOST_WindowIOS *window,
                                                    int mouseX,
                                                    int mouseY,
                                                    void *data)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }
  switch (eventType) {
    case GHOST_kEventDraggingEntered:
    case GHOST_kEventDraggingUpdated:
    case GHOST_kEventDraggingExited:
      window->clientToScreenIntern(mouseX, mouseY, mouseX, mouseY);
      pushEvent(std::make_unique<GHOST_EventDragnDrop>(
          getMilliSeconds(), eventType, draggedObjectType, window, mouseX, mouseY, nullptr));
      break;

    case GHOST_kEventDraggingDropDone: {
      uint8_t *temp_buff;
      GHOST_TStringArray *strArray;
      NSArray *droppedArray;
      size_t pastedTextSize;
      NSString *droppedStr;
      GHOST_TDragnDropDataPtr eventData;
      int i;

      if (!data)
        return GHOST_kFailure;

      switch (draggedObjectType) {
        case GHOST_kDragnDropTypeFilenames:
          droppedArray = (NSArray *)data;

          strArray = (GHOST_TStringArray *)malloc(sizeof(GHOST_TStringArray));
          if (!strArray)
            return GHOST_kFailure;

          strArray->count = [droppedArray count];
          if (strArray->count == 0) {
            free(strArray);
            return GHOST_kFailure;
          }

          strArray->strings = (uint8_t **)malloc(strArray->count * sizeof(uint8_t *));

          for (i = 0; i < strArray->count; i++) {
            droppedStr = [droppedArray objectAtIndex:i];

            pastedTextSize = [droppedStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            temp_buff = (uint8_t *)malloc(pastedTextSize + 1);

            if (!temp_buff) {
              strArray->count = i;
              break;
            }

            strncpy((char *)temp_buff,
                    [droppedStr cStringUsingEncoding:NSUTF8StringEncoding],
                    pastedTextSize);
            temp_buff[pastedTextSize] = '\0';

            strArray->strings[i] = temp_buff;
          }

          eventData = static_cast<GHOST_TDragnDropDataPtr>(strArray);
          break;

        case GHOST_kDragnDropTypeString:
          droppedStr = (NSString *)data;
          pastedTextSize = [droppedStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

          temp_buff = (uint8_t *)malloc(pastedTextSize + 1);

          if (temp_buff == NULL) {
            return GHOST_kFailure;
          }

          strncpy((char *)temp_buff,
                  [droppedStr cStringUsingEncoding:NSUTF8StringEncoding],
                  pastedTextSize);

          temp_buff[pastedTextSize] = '\0';

          eventData = static_cast<GHOST_TDragnDropDataPtr>(temp_buff);
          break;

        case GHOST_kDragnDropTypeBitmap: {
          /* Unsupported iOS. */
          return GHOST_kFailure;
          break;
        }
        default:
          return GHOST_kFailure;
          break;
      }

      pushEvent(std::make_unique<GHOST_EventDragnDrop>(
          getMilliSeconds(), eventType, draggedObjectType, window, mouseX, mouseY, eventData));

      break;
    }
    default:
      return GHOST_kFailure;
  }
  m_outsideLoopEventProcessed = true;
  return GHOST_kSuccess;
}

void GHOST_SystemIOS::handleQuitRequest()
{
  GHOST_Window *window = (GHOST_Window *)window_manager_->getActiveWindow();

  // Discard quit event if we are in cursor grab sequence
  if (window && window->getCursorGrabModeIsWarp())
    return;

  // Push the event to Blender so it can open a dialog if needed
  pushEvent(std::make_unique<GHOST_Event>(getMilliSeconds(), GHOST_kEventQuitRequest, window));
  m_outsideLoopEventProcessed = true;
}

bool GHOST_SystemIOS::handleOpenDocumentRequest(void *filepathStr)
{
  NSString *filepath = (NSString *)filepathStr;

  @autoreleasepool {
    if (!current_active_window) {
      return NO;
    }

    /* Discard event if we are in cursor grab sequence,
     * it'll lead to "stuck cursor" situation if the alert panel is raised. */
    if (current_active_window->getCursorGrabModeIsWarp()) {
      return NO;
    }

    const size_t filenameTextSize = [filepath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    char *temp_buff = (char *)malloc(filenameTextSize + 1);

    if (temp_buff == nullptr) {
      return GHOST_kFailure;
    }

    memcpy(temp_buff, [filepath cStringUsingEncoding:NSUTF8StringEncoding], filenameTextSize);
    temp_buff[filenameTextSize] = '\0';

    pushEvent(std::make_unique<GHOST_EventString>(getMilliSeconds(),
                                    GHOST_kEventOpenMainFile,
                                    current_active_window,
                                    static_cast<GHOST_TEventDataPtr>(temp_buff)));
  }
  return YES;
}



#pragma mark Clipboard get/set

char *GHOST_SystemIOS::getClipboard(bool /*selection*/) const
{
  @autoreleasepool {
    UIPasteboard *pasteBoard = [UIPasteboard generalPasteboard];
    NSString *textPasted = pasteBoard.string;

    if (textPasted == nil) {
      return nullptr;
    }

    const size_t pastedTextSize = [textPasted lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    char *temp_buff = (char *)malloc(pastedTextSize + 1);

    if (temp_buff == nullptr) {
      return nullptr;
    }

    memcpy(temp_buff, [textPasted cStringUsingEncoding:NSUTF8StringEncoding], pastedTextSize);
    temp_buff[pastedTextSize] = '\0';
    return temp_buff;
  }
  return nullptr;
}

void GHOST_SystemIOS::putClipboard(const char *buffer, bool selection) const
{
  if (selection) {
    return; /* For copying the selection, used on X11. */
  }

  @autoreleasepool {
    UIPasteboard *pasteBoard = UIPasteboard.generalPasteboard;
    NSString *textToCopy = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
    [pasteBoard setString:textToCopy];
  }
}

GHOST_IWindow *GHOST_SystemIOS::getWindowUnderCursor(int32_t /*x*/, int32_t /*y*/)
{
  GHOST_ASSERT(FALSE, "GHOST_SystemIOS::getWindowUnderCursor unsupported on iOS");
  return NULL;
}
