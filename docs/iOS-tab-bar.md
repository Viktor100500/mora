# iPhone tab interaction

The screens still live in SwiftUI's `TabView`, with the original `AppRouter.select`
binding and each screen's navigation stack. On iOS 26 phones, an independently
constrained system `UITabBar` supplies the visible control. iPad and older iOS
versions continue to use the controller-owned bar.

The native bar handles glass selection, dragging, accessibility and item layout.
A non-consuming gesture observer holds screen selection until touch release.
Delegate callbacks are processed after event delivery, since the order of native
recognizers and the observer is unspecified. A cancelled touch restores the
routed selection. Activations without a touch sequence, including VoiceOver,
commit without waiting for a finger. Re-selecting the current tab still calls the
router's existing re-selection action.

A 120 ms opacity fade of the old content softens a committed tab change. It does
not move or scale content, reset screen identity, or animate changes to lists.
The transient view excludes the tab bar, ignores touches and accessibility, and
is removed when the fade completes. Native Liquid Glass continues to follow the
system's Reduce Motion setting; the content fade does not override that setting.

Tab width is fixed at the container width plus 24 points. It never changes as a
result of selecting a tab. Full localized labels remain intact.

## Source research

Reviewed the official Telegram iOS sources on 2026-11-12:

- [TabBarComponent gesture handling](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramUI/Components/TabBarComponent/Sources/TabBarComponent.swift#L690): glass responds at gesture begin, but the item action runs on gesture end; cancellation does not select another screen.
- [TabBarController screen changes](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TabBarUI/Sources/TabBarController.swift#L286): the controller uses short alpha and scale animations around a tab change.
- [LiquidLensView](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramUI/Components/LiquidLens/Sources/LiquidLensView.swift): Telegram has its own lens implementation, including private UIKit integration. Its behavior is not the same as an unmodified system `UITabBar`.
- [Telegram's licensing](https://telegram.org/apps#source-code): the iOS application uses GPL v2 or later. Mora's license is different; no Telegram implementation or dependencies were copied.
- [Apple gesture recognizer documentation](https://developer.apple.com/documentation/uikit/uigesturerecognizer): the observer does not cancel or delay native touches and cannot prevent, or be prevented by, other recognizers.

## Manual preview review

- Hold a different tab: glass may react; the current screen stays until release.
- Release, drag between tabs, and drag out of the bar to cancel. Check that the
  final screen and selected item agree, including after rapid repeated taps.
- Check the brief fade with Reduce Motion enabled and disabled. Glass should
  retain the system's accessibility behavior.
- Check all five full labels in English and Russian on iPhone 13 mini, portrait
  and landscape, and after opening and dismissing the keyboard.
- Check VoiceOver activation, re-selecting a tab and preserving each tab's scroll
  position and navigation stack.

Preview builds do not automatically launch the app or Simulator.
