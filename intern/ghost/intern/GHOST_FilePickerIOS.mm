/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Security-scoped URL storage, file picker delegate, and native file dialog
 * implementation for iOS. Extracted from GHOST_SystemIOS.mm.
 */

#include "GHOST_FilePickerIOS.hh"

#include "GHOST_SystemIOS.hh"
#include "GHOST_WindowIOS.hh"

#include "GHOST_EventString.hh"

#include <memory>

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#pragma mark - Security-Scoped URL Storage

/**
 * Dictionary mapping file paths to their original security-scoped NSURLs.
 * Used to maintain access to files/directories returned by UIDocumentPickerViewController.
 * Keys: NSString (absolute path), Values: NSURL (the security-scoped URL from the picker).
 */
static NSMutableDictionary<NSString *, NSURL *> *s_securityScopedURLs = nil;

/** Lock object for thread-safe access to s_securityScopedURLs. */
static NSObject *s_securityScopedURLsLock = [[NSObject alloc] init];

static void storeSecurityScopedURL(NSURL *url)
{
  @synchronized(s_securityScopedURLsLock) {
    if (!s_securityScopedURLs) {
      s_securityScopedURLs = [[NSMutableDictionary alloc] init];
    }
    NSString *path = url.path;
    if (path) {
      s_securityScopedURLs[path] = url;
      /* Also store the parent directory URL for temp file creation during saves. */
      NSURL *dirURL = [url URLByDeletingLastPathComponent];
      if (dirURL && dirURL.path) {
        s_securityScopedURLs[dirURL.path] = dirURL;
      }
    }
  }
}

void GHOST_ios_storeSecurityScopedURL(void *nsurl)
{
  storeSecurityScopedURL((NSURL *)nsurl);
}

static NSURL *lookupSecurityScopedURL(const char *filepath)
{
  @synchronized(s_securityScopedURLsLock) {
    if (!s_securityScopedURLs || !filepath) {
      return nil;
    }
    NSString *path = [NSString stringWithUTF8String:filepath];
    return s_securityScopedURLs[path];
  }
}

void *GHOST_ios_lookupSecurityScopedURL(const char *filepath)
{
  return (void *)lookupSecurityScopedURL(filepath);
}

#pragma mark - Native File Dialog Delegate

/**
 * Objective-C delegate for UIDocumentPickerViewController.
 * On completion, pushes a GHOST_kEventNativeFileDialogResult event with the selected path
 * (or nullptr on cancel) back to the GHOST event queue.
 */
@interface GHOST_IOSFilePickerDelegate
    : NSObject <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, assign) GHOST_SystemIOS *ghostSystem;
/** For save-to-folder mode: the default filename to append to the chosen directory. */
@property(nonatomic, copy) NSString *defaultFilename;
@end

@implementation GHOST_IOSFilePickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
  if (urls.count > 0) {
    NSURL *url = urls.firstObject;

    /* Start security-scoped access so Blender can read/write the file. */
    [url startAccessingSecurityScopedResource];

    /* Store the original security-scoped URL for later access (e.g., saving). */
    storeSecurityScopedURL(url);

    /* For save-to-folder: the user picked a directory, append the default filename. */
    if (_defaultFilename.length > 0) {
      NSURL *fileURL = [url URLByAppendingPathComponent:_defaultFilename];
      storeSecurityScopedURL(fileURL);
      url = fileURL;
    }

    const char *path = [url.path UTF8String];
    const size_t pathLen = strlen(path);
    char *pathCopy = (char *)malloc(pathLen + 1);
    memcpy(pathCopy, path, pathLen + 1);

    GHOST_WindowIOS *window = _ghostSystem->current_active_window;
    _ghostSystem->pushEvent(std::make_unique<GHOST_EventString>(
        _ghostSystem->getMilliSeconds(),
        GHOST_kEventNativeFileDialogResult,
        window,
        static_cast<GHOST_TEventDataPtr>(pathCopy)));
    _ghostSystem->notifyExternalEventProcessed();
  }
  else {
    [self documentPickerWasCancelled:controller];
  }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
  /* Push a cancel event (nullptr data). */
  GHOST_WindowIOS *window = _ghostSystem->current_active_window;
  _ghostSystem->pushEvent(std::make_unique<GHOST_EventString>(
      _ghostSystem->getMilliSeconds(),
      GHOST_kEventNativeFileDialogResult,
      window,
      static_cast<GHOST_TEventDataPtr>(nullptr)));
  _ghostSystem->notifyExternalEventProcessed();
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController
{
  /* Handle swipe-to-dismiss as a cancel. */
  [self documentPickerWasCancelled:nil];
}

@end

#pragma mark - showNativeFileDialog implementation

GHOST_TSuccess GHOST_SystemIOS::showNativeFileDialog(const char *title,
                                                      const char *default_path,
                                                      const char *filter_glob,
                                                      GHOST_TFileDialogAction action)
{
  @autoreleasepool {
    if (!current_active_window) {
      return GHOST_kFailure;
    }

    /* Build an array of UTTypes from the filter_glob.
     * Supported patterns: "*.blend", "*.png;*.jpg", etc.
     * Falls back to UTTypeData (all files) if nothing specific matches. */
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];

    if (filter_glob && filter_glob[0] != '\0') {
      NSString *glob = [NSString stringWithUTF8String:filter_glob];
      /* Split by common separators: ";", " ", ",". */
      NSArray<NSString *> *patterns = [glob
          componentsSeparatedByCharactersInSet:
              [NSCharacterSet characterSetWithCharactersInString:@"; ,"]];

      for (NSString *pattern in patterns) {
        NSString *ext = pattern;
        /* Strip leading "*." or "." */
        if ([ext hasPrefix:@"*."]) {
          ext = [ext substringFromIndex:2];
        }
        else if ([ext hasPrefix:@"."]) {
          ext = [ext substringFromIndex:1];
        }

        if (ext.length == 0) {
          continue;
        }

        UTType *type = [UTType typeWithFilenameExtension:ext];
        if (type) {
          [contentTypes addObject:type];
        }
      }
    }

    /* If no specific types were resolved, allow all content. */
    if (contentTypes.count == 0) {
      [contentTypes addObject:UTTypeData];
      [contentTypes addObject:UTTypeFolder];
    }

    UIDocumentPickerViewController *picker = nil;

    /* Extract the default filename from default_path for save operations. */
    NSString *saveFilename = nil;

    if (action == GHOST_kFileDialogOpen) {
      picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
      picker.allowsMultipleSelection = NO;
    }
    else {
      /* For save, use a folder picker. The user picks a destination directory, and Blender
       * writes the file directly into it with security-scoped access. This avoids the
       * initForExportingURLs approach which copies a placeholder — the copy is often not
       * writable afterward in the file provider's domain, leading to 0 KB files. */
      saveFilename = @"untitled.blend";
      if (default_path && default_path[0] != '\0') {
        NSString *pathStr = [NSString stringWithUTF8String:default_path];
        NSString *lastComponent = [pathStr lastPathComponent];
        if (lastComponent.length > 0 && [lastComponent containsString:@"."]) {
          saveFilename = lastComponent;
        }
      }

      picker = [[UIDocumentPickerViewController alloc]
          initForOpeningContentTypes:@[ UTTypeFolder ]];
      picker.allowsMultipleSelection = NO;
    }

    if (!picker) {
      return GHOST_kFailure;
    }

    /* Create and retain the delegate. The delegate will be released when the picker is dismissed.
     * We use objc_setAssociatedObject to tie its lifetime to the picker. */
    GHOST_IOSFilePickerDelegate *delegate = [[GHOST_IOSFilePickerDelegate alloc] init];
    delegate.ghostSystem = this;
    delegate.defaultFilename = saveFilename;
    picker.delegate = delegate;
    picker.presentationController.delegate = delegate;

    /* Tie delegate lifetime to picker via associated object. */
    objc_setAssociatedObject(
        picker, "ghost_delegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (title) {
      picker.title = [NSString stringWithUTF8String:title];
    }

    /* Set initial directory if available. */
    if (default_path && default_path[0] != '\0') {
      NSString *pathStr = [NSString stringWithUTF8String:default_path];
      BOOL isDir = NO;
      if ([[NSFileManager defaultManager] fileExistsAtPath:pathStr isDirectory:&isDir]) {
        NSURL *dirURL;
        if (isDir) {
          dirURL = [NSURL fileURLWithPath:pathStr];
        }
        else {
          dirURL = [[NSURL fileURLWithPath:pathStr] URLByDeletingLastPathComponent];
        }
        picker.directoryURL = dirURL;
      }
    }

    /* Present the picker from the root view controller. */
    UIWindow *uiWindow = current_active_window->rootWindow;
    UIViewController *rootVC = uiWindow.rootViewController;
    if (!rootVC) {
      return GHOST_kFailure;
    }

    /* For save operations, prompt the user for a filename before showing the folder picker. */
    if (action == GHOST_kFileDialogSave && saveFilename.length > 0) {
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:@"Save As"
                           message:@"Enter filename:"
                    preferredStyle:UIAlertControllerStyleAlert];

      [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = saveFilename;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        /* Select just the name part, without extension. */
        NSRange dotRange = [saveFilename rangeOfString:@"." options:NSBackwardsSearch];
        if (dotRange.location != NSNotFound) {
          UITextPosition *start = textField.beginningOfDocument;
          UITextPosition *end = [textField positionFromPosition:start
                                                        offset:(NSInteger)dotRange.location];
          if (start && end) {
            dispatch_async(dispatch_get_main_queue(), ^{
              textField.selectedTextRange = [textField textRangeFromPosition:start
                                                                 toPosition:end];
            });
          }
        }
      }];

      [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                style:UIAlertActionStyleCancel
                                              handler:^(UIAlertAction *_Nonnull a) {
                                                /* Push a cancel event. */
                                                GHOST_WindowIOS *window =
                                                    this->current_active_window;
                                                this->pushEvent(
                                                    std::make_unique<GHOST_EventString>(
                                                        this->getMilliSeconds(),
                                                        GHOST_kEventNativeFileDialogResult,
                                                        window,
                                                        static_cast<GHOST_TEventDataPtr>(
                                                            nullptr)));
                                                this->notifyExternalEventProcessed();
                                              }]];

      [alert
          addAction:[UIAlertAction
                        actionWithTitle:@"Save"
                                  style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *_Nonnull a) {
                                  NSString *newFilename = alert.textFields.firstObject.text;
                                  if (newFilename.length > 0) {
                                    delegate.defaultFilename = newFilename;
                                  }
                                  /* Now show the folder picker. */
                                  [rootVC presentViewController:picker
                                                       animated:YES
                                                     completion:nil];
                                }]];

      UIViewController *presenter = rootVC.presentedViewController ?: rootVC;
      if (presenter.presentedViewController) {
        [presenter dismissViewControllerAnimated:NO
                                      completion:^{
                                        [rootVC presentViewController:alert
                                                             animated:YES
                                                           completion:nil];
                                      }];
      }
      else {
        [presenter presentViewController:alert animated:YES completion:nil];
      }
    }
    else {
      /* Open mode or no filename — show the picker directly. */
      if (rootVC.presentedViewController) {
        [rootVC dismissViewControllerAnimated:NO
                                   completion:^{
                                     [rootVC presentViewController:picker
                                                          animated:YES
                                                        completion:nil];
                                   }];
      }
      else {
        [rootVC presentViewController:picker animated:YES completion:nil];
      }
    }

    return GHOST_kSuccess;
  }
}

#pragma mark - Security-Scoped File Access

GHOST_TSuccess GHOST_SystemIOS::startSecurityScopedFileAccess(const char *filepath)
{
  /* First try to use a stored security-scoped URL from the file picker.
   * Plain NSURLs created from path strings are NOT security-scoped and
   * calling startAccessingSecurityScopedResource on them is a no-op. */
  NSURL *url = lookupSecurityScopedURL(filepath);
  if (!url) {
    /* Also try the parent directory — Blender writes to temp files in the same dir. */
    NSString *path = [NSString stringWithUTF8String:filepath];
    NSString *parentPath = [path stringByDeletingLastPathComponent];
    url = lookupSecurityScopedURL([parentPath UTF8String]);
  }
  if (!url) {
    /* Fallback to a plain URL (works for paths within the sandbox). */
    url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filepath]];
  }
  BOOL success = [url startAccessingSecurityScopedResource];
  return success ? GHOST_kSuccess : GHOST_kFailure;
}

GHOST_TSuccess GHOST_SystemIOS::stopSecurityScopedFileAccess(const char *filepath)
{
  NSURL *url = lookupSecurityScopedURL(filepath);
  if (!url) {
    url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filepath]];
  }
  [url stopAccessingSecurityScopedResource];
  return GHOST_kSuccess;
}
