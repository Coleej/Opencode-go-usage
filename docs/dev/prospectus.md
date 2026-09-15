I couldn’t find a public **DankMaterialShell (DMS)** plugin specifically for OpenCode Zen/Go quota or usage limits. There are several quota widgets for other host UIs—mainly DeepSeek Harness—but not an indexed DMS equivalent. [github](https://github.com/dshworks/awesome-dsh-plugins/blob/main/lists/usage-cost.md

## Fastest option: a local DMS widget

This is a very small DMS plugin: it runs a local script, displays its first-line output in DankBar, and refreshes periodically. The only unknown is the exact authenticated Zen usage endpoint/response format your OpenCode installation can access, so put that logic in the script rather than embedding credentials in QML.

Create:

```text
~/.config/DankMaterialShell/plugins/OpenCodeGoUsage/
├── plugin.json
├── OpenCodeGoUsage.qml
└── opencode-go-usage.sh
```

### `plugin.json`

```json
{
  "id": "opencodeGoUsage",
  "name": "OpenCode Go Usage",
  "description": "Shows OpenCode Zen Go quota usage in DankBar",
  "version": "0.1.0",
  "author": "Cody",
  "icon": "data_usage",
  "type": "widget",
  "component": "./OpenCodeGoUsage.qml",
  "permissions": []
}
```

### `OpenCodeGoUsage.qml`

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property string usageText: "OC: …"
    property string script: Quickshell.env("HOME"
        + "/.config/DankMaterialShell/plugins/OpenCodeGoUsage/opencode-go-usage.sh"

    function refresh() {
        usageProcess.running = true
    }

    Process {
        id: usageProcess
        command: ["sh", root.script]

        stdout: SplitParser {
            onRead: line => {
                if (line.trim().length > 0
                    root.usageText = line.trim(
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0
                root.usageText = "OC: error"
        }
    }

    Timer {
        interval: 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh(
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: "data_usage"
                size: Theme.iconSize
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.usageText
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "data_usage"
                size: Theme.iconSize
                color: Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.usageText
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    Component.onCompleted: refresh(
}
```

DMS’s documented plugin model supports bar widgets based on `PluginComponent`, shell commands/processes, per-plugin settings/state, and runtime reloads, so this is a normal lightweight plugin rather than a fork/patch of the shell. [danklinux](https://danklinux.com/docs/dankmaterialshell/plugin-development

## Script interface

Make `opencode-go-usage.sh` executable:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Replace this command with your authenticated usage fetch + jq formatting.
# It must print exactly one short line for DankBar.
#
# Desired output examples:
#   OC 5h: 68% · wk: 42% · mo: 18%
#   OC 5h: 32% left · wk: 58% left
#   OC: limit reached

printf 'OC: configure\n'
```

Then:

```bash
chmod +x ~/.config/DankMaterialShell/plugins/OpenCodeGoUsage/opencode-go-usage.sh
dms ipc call plugins reload opencodeGoUsage
```

Or use **DMS Settings → Plugins → Scan for Plugins**, enable it, then add **OpenCode Go Usage** to DankBar. DMS supports both scanning/enabling through Settings and plugin reload/status commands from `dms ipc`. [danklinux](https://danklinux.com/docs/dankmaterialshell/plugin-development

## Where to obtain the data

The quota implementations I found describe a Zen/Go usage API endpoint at `/zen/go/v1/usage`, and show the meaningful windows as a rolling five-hour limit plus weekly and monthly limits. Treat the endpoint and its authorization scheme as implementation details to verify from your current OpenCode session/version rather than hard-coding them blindly. [github](https://github.com/dshworks/awesome-dsh-plugins/blob/main/lists/usage-cost.md

For example, after confirming the endpoint and header/cookie your own client uses, the script could conceptually become:

```bash
#!/usr/bin/env bash
set -euo pipefail

usage="$(
  curl --fail --silent --show-error \
    -H "Authorization: Bearer $OPENCODE_ZEN_TOKEN" \
    "https://opencode.ai/zen/go/v1/usage"
)"

jq -r '
  "OC 5h: \(.rolling_5h.percent|round)% · wk: \(.weekly.percent|round)% · mo: \(.monthly.percent|round)%"
' <<<"$usage"
```

I would keep the token in a systemd user credential, `pass`/`gopass`, or another secret mechanism—not in the plugin directory or Nix store. If OpenCode already has a local credential file, a safer approach may be for the script to invoke the existing CLI/client code rather than replicate its auth.

## Better version

The most polished implementation would be a **composite DMS plugin**:

- A daemon refreshes the authenticated quota JSON every 60–120 seconds.
- A bar pill shows a compact label such as `OC 5h 68%`.
- A click popout displays five-hour/week/month percentages, reset times, last refresh, and any fetch error.
- The daemon stores only non-secret cached results via DMS plugin state.

DMS explicitly supports composite plugins with daemon and bar-widget surfaces, shared runtime state, and popout widget content, which makes that design straightforward. [danklinux](https://danklinux.com/docs/dankmaterialshell/plugin-development

If you want, I can write the full DMS composite plugin next—but I’d need either a sample redacted response from the Zen usage endpoint or the OpenCode command/auth path you’re using so the `jq` mapping is correct.
