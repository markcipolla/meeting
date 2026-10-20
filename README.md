# Meetings

MeetingBar replacement with no Google auth. macOS subscribes to the ICS feed;
this app reads it and puts the next meeting in the menu bar.

## Install

```sh
brew tap markcipolla/meeting https://github.com/markcipolla/meeting
brew install meetings
ln -sfn "$(brew --prefix)/opt/meetings/Meetings.app" /Applications/Meetings.app
open /Applications/Meetings.app
```

It builds from source (Xcode command line tools), so there is no Gatekeeper
quarantine and nothing to notarize. Grant calendar access when asked, and add it
to Login Items to start at boot.

Then subscribe to your work ICS feed — no OAuth, Calendar.app does the fetching,
recurrence expansion and timezones:

```sh
open "webcal://example.com/path/to/your.ics"   # or Calendar ▸ File ▸ New Calendar Subscription
```

Set **Auto-refresh: Every 5 minutes** in the subscription dialog.

## Use

- Menu bar shows the next meeting and a countdown.
- Menu: join the next one (⌘J), the rest of today, next 7 days window (⌘K).
- **Settings…** picks which app opens each service — Google Meet, Teams, Zoom and
  everything else, each either the system default or a specific app (Chrome, the
  Meet PWA, Teams desktop, …). Teams links sent to Teams desktop are rewritten to
  `msteams:` so they don't bounce through a browser.
- Join links are read from the event location, URL and notes. Every candidate is
  ranked, so a conference link beats an agenda link wherever it sits in the
  description; Google's `www.google.com/url?q=` wrappers are unwrapped first, and
  its boilerplate (`tel.meet`, `support.google.com`, `aka.ms`) is never picked.
- **Open meetings automatically**, n minutes beforehand (off by default). Only
  Meet, Teams and Zoom links auto-open — never a random link.
- **Copy debug info** in Settings dumps what the link picker sees for each event,
  if it ever picks the wrong link.

## Updates

The app checks the GitHub releases API at launch and every 6 hours. When a newer
tag exists the menu offers **Update to x.y.z**, which runs `brew upgrade` and
relaunches (log in `/tmp/meetings-update.log`). Without Homebrew on PATH it opens
the releases page instead.

## Releasing

```sh
git tag v0.2.0 && git push origin main --tags
```

`.github/workflows/release.yml` builds, runs the self-test, cuts the GitHub
release and commits the new `url`/`sha256` into `Formula/meetings.rb` on main —
this repo is its own Homebrew tap, so there is no second repo to keep in sync.
`ci.yml` builds and self-tests every push and PR.

`./build.sh` builds locally into `build/`;
`./build/Meetings.app/Contents/MacOS/Meetings --selftest` checks link detection,
service routing and the Teams URL rewrite.
