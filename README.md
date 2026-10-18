# Siprup 💧

A playful hydration log for iOS: the whole phone screen is the side of a glass, and the drinks you log pour in as coloured, labelled layers. It's a visual log, not a hydration measurement or medical advice.

## Stack
Only Apple's built-in frameworks, so there are no third-party dependencies:
- **SwiftUI** + `Canvas`/`TimelineView` for the liquid (waves, bubbles, beer foam)
- **SwiftData** for local drink history, drink types and per-day goals
- **Swift Charts** for the 7-day history chart
- **UserNotifications** for gentle reminders (quiet hours, pause, a "Pause for today" action, and no reminders once the goal is met)
- **CoreMotion** to tilt and slosh the liquid (it stays still in the simulator and with Reduce Motion on)
- **XcodeGen** generates `Siprup.xcodeproj` from `project.yml`

## Run
```bash
xcodegen generate
open Siprup.xcodeproj   # iOS 17+, iPhone simulator
```
Debug launch arguments:
- `-SiprupInMemory` uses a throwaway store
- `-SiprupDemoData` seeds today plus 7 past days
- `-SiprupOpenSheet add|today|history|settings|info` opens a screen at launch

## Tests
```bash
xcodebuild test -project Siprup.xcodeproj -scheme Siprup -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```
These cover the day-reset maths, unit conversion, nutrition sums and reminder scheduling.
