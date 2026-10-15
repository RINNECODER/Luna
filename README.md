```text
                              ████▒▓
                           ░██▓▒█▓▓▓ ▓ ▒█░░▓
                     █░▒   :-==-;~+ ▓░░▓▓▓░  ▓      ▒
                    `:;-~=++**xxx+~~=+=*ox▒▒▓   ▓ ▓ ▒     ░
                 '`::-~~~=+*xxxoaox**=~~=+*xo·▒▓█░▒    ▒
               .`,,:-~~==+**xxxoaooooooxxx++oNA%B░▓             ░
           .  '`,::;;~=+*xooxx*xeO##%&&&&%###%@&%%E               ▒░▓
          ....'`::;~=+*xxx***xxxxoeO&@@@@&&&@@@@@@@%·             ▒▒░
      ░.     .'`,:;~++*******xxoooxaO&@@@@@@@&%@@&@@@S    ▓        ░
           ...''`,:-~++++=~+xxxxoooaaeeO#%&@@%Oe#&&%·%O  ▓ ▓        ░
   ░░     . .'''`,:;-~=~~~=+*xoaaaaBKIT·MOONLOexoae#eoae █
   █..      .''`,:::;-~~~==*xxxoaaaT·LUNA·BROaeaooooaxxoo░█▓     ▒  ░░
█▒▒█     ....'`,,:::;--~~~=++**xxoaR·SWIFT·WEaeaxxxoooooo+██
█▓░        ..'``,::;;;-~~=====++*xoT·MOONLIGHOao***xooeeex░▒
   .  .      '`,,:;;---~~===~~~=++xooaeaROWSEeax*+**xxaOea=
   ..  . ..  '`,,:;--~~~===+====++*xxoeOWEBKIaax+=+*+xaOOe+
░▓▒ .       ..'`,::;---~~~==++KIT·M**oaeGHT·LUNA·B**xoeO#e*
▓▓▓           '``,,::::;;;;-=+·LUNA*xoaeSER·SWIFT·OOOOOOOa*
 █▒.  . .  . . ''`,,,,,,::;-~+*xxxxT·WEBKIT·MaeO#%@%####Oe
 ▓▓▓ .     . .  ''`````,,::;-~=+xxoLIGHT·LUNA#%%%&&ee%%%%#
   ▒.       .    .''````,:;;;~=+xxooooaaaaeO#%%%&e*=*O%#O▓░
   ░▓.            ''``,,,:;;-~=+*xxxxxooooeO##%&ex=+xOea ▒
         . .       ''`,,,::;-~ONLIG*xxxxoaeeOO##o**xoox▒▓
               .    .'`,,,,:;--ROWS+*xooxoooooooaox+*+▒
      █▒░.      ..  . '```,,:;-~~~~=+*xxxx**xxxx**=+
      ▒▒░   .       . . '``,::;---~~~~~=***xxxx*+~-
           ░░      ..     ''`,:::;--;;-~~=+==I;;;
             ▓▓▓..    ..  .  '``,,,,:::;;-;:,,
                  ░▓ ..   .     ..''''``''██▒
                  ▓▒▒░░█   .   . .        █▓░
                                       █░▓
```

<h1 align="center">Luna</h1>

<p align="center"><b>A quieter browser for the Mac.</b><br>
Native Swift and WebKit, with an AI assistant that shows up when you ask and stays out of the way when you don't.</p>

<p align="center">
  <a href="https://rahul4301.github.io/Luna/">Website</a> ·
  <a href="https://github.com/Rahul4301/Luna/releases/latest">Download</a> ·
  <a href="https://github.com/Rahul4301/Luna/issues">Report an issue</a>
</p>

<p align="center">
  <img alt="macOS 15.4+" src="https://img.shields.io/badge/macOS-15.4%2B-111?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-WebKit-111?style=flat-square">
  <img alt="Xcode 26" src="https://img.shields.io/badge/Xcode-26-111?style=flat-square">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-111?style=flat-square">
</p>

> [!WARNING]
> Luna is in early development and not ready for everyday use yet. Expect rough edges, and please [tell us about them](https://github.com/Rahul4301/Luna/issues).

---

## Why Luna

- **Native, not ported.** SwiftUI on WebKit, the engine behind Safari. No Electron, no Chromium.
- **Search first.** The start page sends lookups to Google. Chat is one `⌘↩` away, never in the way.
- **Your model, your Mac.** Run AI locally with Ollama, or use Google Gemini.
- **Private by default.** uBlock Origin Lite built in, API keys in your Keychain, nothing collected.

## Features

**Browsing**

- Tabs in a sidebar or along the top, with drag to reorder, pinned tabs and favorites
- Drag a tab into another window, or out onto the desktop for a new window
- Split view: drop one tab onto another to see both side by side
- Address bar with autocomplete, search suggestions and history
- Downloads hub, find in page, print, zoom and keyboard shortcuts for everything

**Luna AI**

- Side panel that chats about the page you're on (`⌘E`)
- Add other tabs or files as context: PDF, TXT, MD, JSON, CSV, XML, HTML
- Per-tab chat history with summaries
- Markdown, code and LaTeX in answers
- Browser commands in plain language: "open a new tab", "go to…"

**Privacy**

- uBlock Origin Lite, bundled
- API keys stored in the macOS Keychain
- App sandbox with minimal permissions

## Get Luna

1. Download `Luna.dmg` from the [latest release](https://github.com/Rahul4301/Luna/releases/latest).
2. Open it and drag Luna into Applications.
3. If macOS says it can't check the app, right-click Luna and choose **Open**.

## Bring your own model

Luna works with Google Gemini (cloud) or any model in your local [Ollama](https://ollama.com/download) install. For the best results we recommend [gpt-oss 120B](https://ollama.com/library/gpt-oss:120b), OpenAI's open-weight model with full chain of thought and native tool calling, under Apache 2.0:

```bash
ollama run gpt-oss:120b
```

Then in Luna, open **Settings › AI & Models**, choose **Ollama** and pick `gpt-oss:120b`.

## Build from source

You need Xcode 26 and macOS 15.4 or later.

```bash
git clone https://github.com/Rahul4301/Luna.git
cd Luna
./scripts/setup.sh
```

Set your Apple Team ID in `Signing.xcconfig` (the setup script creates it). Find yours under [Membership details](https://developer.apple.com/account#MembershipDetailsCard):

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Then open `Luna.xcodeproj` and press `⌘R`.

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) and isn't checked in. Run `xcodegen` again after changing `project.yml` or pulling changes to the project structure.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘T` | New tab |
| `⌘W` | Close tab |
| `⌘L` | Focus the address bar |
| `⌘E` | Toggle the AI panel |
| `⌘F` | Find in page |
| `⌘Y` | History |
| `⌘1`–`⌘9` | Jump to a tab |
| `⌘+` / `⌘−` / `⌘0` | Zoom in, out, reset |

## Contributing

Contributions are welcome.

1. Fork the repo and create a branch: `git checkout -b feature/your-feature`
2. Run `./scripts/setup.sh` and set up signing as above.
3. Make your change, then build and test.
4. Don't commit `Signing.xcconfig` or anything containing your Team ID.
5. Open a pull request against `main`.

## License

[MIT](LICENSE). Use it, fork it and ship it, as long as the copyright notice comes along.
