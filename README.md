# Apiapp

A focused Mac app for hitting APIs and keeping the requests. Native SwiftUI, no accounts, all local.

## Running it

Open `Apiapp.xcodeproj` in Xcode and press ⌘R, or build from the command line:

```bash
xcodebuild -project Apiapp.xcodeproj -scheme Apiapp -configuration Release -derivedDataPath build/DerivedData build
```

The app ends up at `build/DerivedData/Build/Products/Release/Apiapp.app`. It needs macOS 26.

Run the tests with:

```bash
xcodebuild test -project Apiapp.xcodeproj -scheme Apiapp -destination 'platform=macOS'
```

## Shortcuts

| Action | Keys |
| --- | --- |
| Send | ⌘↩ (or Return in the URL field) |
| Cancel | ⌘. |
| Save | ⌘S |
| New request | ⌘N |
| Close tab | ⌘W |
| Quick open | ⌘K |
| Go to URL | ⌘L |
| Format JSON | ⌘⇧F |
| Find | ⌘F |
| Next / previous tab | ⌘⇧] / ⌘⇧[ |

## Where things are kept

Everything is plain JSON in `~/Library/Application Support/Apiapp`:

```
requests/<id>.json     saved requests
history/<id>.json      the last 500 sent requests, bodies included
responses/<id>.json    saved responses
folders.json           folders
environments.json      environments and variables
workspace.json         open tabs
```

Auth tab tokens, passwords and API keys, and variables marked Secret, are kept in the Keychain and left out of those files. A value that is only a `{{variable}}` reference stays in the file, since it isn't secret itself. Anything in the Headers table or a body is saved as plain text. put credentials in the Auth tab or a secret variable.

## Other Behavior

- **Removing Content-Type on a POST sends it blank.** macOS adds `application/x-www-form-urlencoded` to any POST body with no Content-Type, and a blank value is the only way to stop it. Other methods leave the header out entirely.
- **GET and HEAD can't have a body.** macOS refuses to send one, so the app sends warning instead of dropping it silently (maybe should drop it?).
- **Unknown variables** stop the request if they're in the URL, headers, params or auth. In a body they're left as typed, since double braces can be real content.
- **No cookies are kept** between requests, and responses aren't cached, so each send contains exactly what the tab shows. Redirects are followed.
