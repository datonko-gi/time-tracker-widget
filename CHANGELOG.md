# Changelog

## v1.0.0 (2026-10-19)

First public release.

- Weekly project time tracking: one knob, up to 5 projects, plan hours per project, plan vs actual bars.
- Default projects on a 40 h week: Client work 15, Product 10, Learning 5, Admin 5, Other 5.
- Idle detection (auto-pause after 25 minutes without input), crash recovery with a 60 second heartbeat.
- Global hotkeys: Ctrl+Alt+Shift+9 start or stop, Ctrl+Alt+Shift+1 to 5 switch project.
- Analytics window with per-day hours for the current and past weeks.
- English interface. Days and weeks follow the local time zone.
- `uninstall.bat` no longer matches its own PowerShell process when it stops the widget.
- `install.bat` works from folders with an apostrophe in the path and reports a failed shortcut instead of claiming success.
- Dates are always written and read in the invariant culture, so history is consistent on PCs with a non-Gregorian calendar or a different time separator.
- The project limit is 5, matching the five rows the widget can draw.
