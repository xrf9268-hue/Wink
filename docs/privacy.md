# Privacy

Wink is a local-first macOS utility. This page describes the behavior in the current codebase so the in-app `Privacy` link stays truthful.

## What Wink stores locally

- saved shortcuts and related configuration in your local app-support data
- local usage-insights data used to render the Insights tab
- local settings such as Hyper-key state, launch-at-login state, selected Settings tab, and other UI preferences
- imported or exported shortcut recipe files only when you explicitly choose a file in the open/save panels

## Permissions

Wink may ask for:

- `Accessibility`, so it can register and route global shortcuts
- `Input Monitoring`, only when your current enabled shortcut set requires the Hyper-key event-tap path

These permissions are used locally on your Mac to capture and route shortcuts. They are not analytics permissions and do not send shortcut events to a Wink server.

## Network access

Wink does not include a user account system or built-in product analytics in the current codebase.

Wink may contact external hosts in these cases:

- when you manually click `Check for Updates…`
- when a signed release build is configured to check for updates through Sparkle
- when you open external links such as Release Notes, Support, or this Privacy page

In those cases, network requests go to the configured update feed, release host, or external website you chose to open.

## What Wink does not currently do

- it does not require you to sign in
- it does not sync your shortcuts to a Wink cloud service
- it does not upload your usage-insights database as part of normal app behavior

If the product gains new data collection or remote services later, update this document and the in-app link in `GeneralTabView.swift` in the same change.
