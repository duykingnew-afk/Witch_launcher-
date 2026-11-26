// PE Buttons: built-in PE-style skin for the in-game touch controls.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Installs the control hooks (ControlButton / ControlJoystick) when the control.pe_buttons
// preference is on, which is the default. Does nothing if another plugin has already
// skinned the controls, so they are never hooked twice. Call once from
// -application:didFinishLaunchingWithOptions:, after the plugins have loaded.
void PEButtonsInstallIfEnabled(void);

NS_ASSUME_NONNULL_END
