import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "opencodeGoUsage"

    StyledText {
        width: parent.width
        text: "OpenCode Go Usage"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Shows OpenCode Go 5-hour, weekly, and monthly usage windows in DankBar, with reset countdowns. The API key is read automatically from ~/.local/share/opencode/auth.json."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "pollIntervalSec"
        label: "Refresh interval"
        description: "How often usage is fetched"
        defaultValue: 120
        minimum: 30
        maximum: 600
        unit: "sec"
    }

    ToggleSetting {
        settingKey: "showResetInPill"
        label: "Show 5h reset countdown in bar"
        defaultValue: false
    }

    StyledText {
        width: parent.width
        text: "Zen balance (optional): paste your opencode.ai auth cookie (browser devtools → Application → Cookies → auth). The cookie expires periodically and must be re-pasted. Setting your workspace ID (wrk_… from the workspace URL) makes balance lookups more reliable."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "zenCookie"
        label: "Zen auth cookie"
        description: "Enables the Zen balance row in the popout"
        placeholder: "auth=…"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "zenWorkspaceId"
        label: "Workspace ID (optional)"
        description: "wrk_… from your workspace URL; skips auto-discovery"
        placeholder: "wrk_…"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "scriptPath"
        label: "Helper script path (advanced)"
        description: "Only needed if this plugin is not installed at ~/.config/DankMaterialShell/plugins/opencode-go-usage"
        placeholder: "/path/to/opencode-go-usage.sh"
        defaultValue: ""
    }
}
