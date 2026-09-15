import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "opencode-go-usage"

    // ---- settings (auto-synced from plugin settings) ----
    property int pollIntervalSec: pluginData.pollIntervalSec ?? 120
    property bool showResetInPill: pluginData.showResetInPill ?? false
    property string zenCookie: pluginData.zenCookie ?? ""
    property string zenWorkspaceId: pluginData.zenWorkspaceId ?? ""
    property string scriptPath: (pluginData.scriptPath && pluginData.scriptPath.length > 0)
        ? pluginData.scriptPath
        : Quickshell.env("HOME") + "/.config/DankMaterialShell/plugins/opencode-go-usage/opencode-go-usage.sh"

    // ---- runtime state ----
    property var usage: null
    property var balance: null
    property string balanceError: ""
    property string lastError: ""
    property bool stale: false
    property int fetchedAt: 0
    property date now: new Date()
    property string buffer: ""

    readonly property var windowKeys: ["rolling", "weekly", "monthly"]

    // ---- helpers ----
    function pct(win) {
        return (usage && usage[win] && usage[win].percent !== undefined && usage[win].percent !== null)
            ? Math.round(usage[win].percent) : null
    }
    function worstPct() {
        const vals = [pct("rolling"), pct("weekly"), pct("monthly")].filter(v => v !== null)
        return vals.length > 0 ? Math.max.apply(null, vals) : null
    }
    function statusColor(p) {
        if (p === null || stale)
            return Theme.surfaceVariantText
        if (p >= 90)
            return Theme.error
        if (p >= 70)
            return Theme.warning
        return Theme.success
    }
    function windowLabel(key) {
        if (key === "rolling")
            return "5-hour"
        if (key === "weekly")
            return "Weekly"
        return "Monthly"
    }
    function fmtCountdown(iso) {
        if (!iso)
            return "?"
        const ms = new Date(iso).getTime()
        if (isNaN(ms))
            return "?"
        const diff = Math.max(0, Math.floor((ms - root.now.getTime()) / 1000))
        const d = Math.floor(diff / 86400)
        const h = Math.floor((diff % 86400) / 3600)
        const m = Math.floor((diff % 3600) / 60)
        if (d > 0)
            return d + "d" + h + "h"
        if (h > 0)
            return h + "h" + m + "m"
        return m + "m"
    }
    function fmtResetAbs(iso) {
        if (!iso)
            return ""
        const d = new Date(iso)
        if (isNaN(d.getTime()))
            return ""
        return Qt.formatDateTime(d, "ddd MMM d HH:mm")
    }
    function fmtAge(ts) {
        if (!ts || isNaN(ts))
            return "never"
        const diff = Math.max(0, Math.floor(root.now.getTime() / 1000 - ts))
        if (diff < 60)
            return "just now"
        const m = Math.floor(diff / 60)
        const h = Math.floor(m / 60)
        if (h > 0)
            return h + "h" + (m % 60) + "m ago"
        return m + "m ago"
    }
    function pillText() {
        if (!usage)
            return lastError === "no_key" ? "OC: no key" : "OC: …"
        let s = "5h " + (pct("rolling") ?? "--") + "% · wk " + (pct("weekly") ?? "--") + "% · mo " + (pct("monthly") ?? "--") + "%"
        if (showResetInPill && usage.rolling)
            s += " ↻" + fmtCountdown(usage.rolling.resetsAt)
        if (stale)
            s += " ⚠"
        return s
    }
    function balanceText() {
        if (balance !== null && balance.usd !== undefined && !isNaN(Number(balance.usd)))
            return "$" + Number(balance.usd).toFixed(2)
        if (balanceError === "not_configured")
            return "add cookie in settings"
        if (balanceError === "auth")
            return "cookie expired — re-paste in settings"
        return "unavailable"
    }
    function balanceColor() {
        if (balance !== null)
            return Theme.primary
        if (balanceError === "auth")
            return Theme.error
        return Theme.surfaceVariantText
    }
    function errorText() {
        if (lastError === "no_key")
            return "No OpenCode API key found in ~/.local/share/opencode/auth.json"
        if (lastError === "auth")
            return "Usage API authentication failed (401/403)"
        if (lastError === "parse")
            return "Unexpected response from the usage API"
        if (lastError === "missing_dep")
            return "Missing dependencies: curl, jq, or flock"
        if (lastError === "script")
            return "Helper script failed — check scriptPath in settings"
        if (lastError !== "")
            return "Fetch error: " + lastError
        return ""
    }

    function poll(force) {
        if (pollProc.running)
            return
        root.buffer = ""
        pollProc.command = force ? ["sh", root.scriptPath, "--force"] : ["sh", root.scriptPath]
        pollProc.running = true
    }
    function refresh() {
        poll(true)
    }

    Process {
        id: pollProc
        environment: ({
                "OPENCODE_GO_COOKIE": root.zenCookie,
                "OPENCODE_GO_WORKSPACE_ID": root.zenWorkspaceId
            })
        stdout: SplitParser {
            onRead: line => {
                root.buffer += line + "\n"
            }
        }
        onExited: (exitCode, exitStatus) => {
            const text = root.buffer.trim()
            if (exitCode !== 0 || text.length === 0) {
                root.lastError = "script"
                return
            }
            try {
                const data = JSON.parse(text.split("\n").pop())
                root.lastError = data.error || ""
                root.stale = !!data.stale
                root.fetchedAt = data.fetchedAt || 0
                if (data.usage)
                    root.usage = data.usage
                root.balance = data.balance || null
                root.balanceError = data.balanceError || ""
            } catch (e) {
                root.lastError = "parse"
            }
        }
    }

    Timer {
        interval: Math.max(30, root.pollIntervalSec) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.poll(false)
    }

    // 1s tick that drives the countdown re-rendering (no network traffic)
    Timer {
        interval: 1000
        running: root.usage !== null
        repeat: true
        onTriggered: root.now = new Date()
    }

    pillRightClickAction: () => root.refresh()

    // ---- bar pills ----
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            DankIcon {
                name: "data_usage"
                size: root.iconSize
                color: root.statusColor(root.worstPct())
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                color: root.statusColor(root.worstPct())
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS
            DankIcon {
                name: "data_usage"
                size: root.iconSize
                color: root.statusColor(root.worstPct())
                anchors.horizontalCenter: parent.horizontalCenter
            }
            StyledText {
                text: root.pct("rolling") !== null ? root.pct("rolling") + "%" : "…"
                font.pixelSize: Theme.fontSizeSmall
                color: root.statusColor(root.pct("rolling"))
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ---- popout ----
    popoutWidth: 380
    popoutHeight: 420

    popoutContent: Component {
        PopoutComponent {
            id: pop
            headerText: "OpenCode Go"
            detailsText: root.usage
                ? "Updated " + root.fmtAge(root.fetchedAt) + (root.stale ? " — stale, retrying" : "")
                : "No data yet"
            showCloseButton: true

            headerActions: Component {
                Rectangle {
                    width: 32
                    height: 32
                    radius: 16
                    color: refreshArea.containsMouse ? Theme.primaryHover : "transparent"
                    DankIcon {
                        anchors.centerIn: parent
                        name: "refresh"
                        size: Theme.iconSize - 4
                        color: Theme.surfaceText
                    }
                    MouseArea {
                        id: refreshArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.refresh()
                    }
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - pop.headerHeight - pop.detailsHeight - Theme.spacingXL

                Column {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    anchors.topMargin: Theme.spacingXS
                    spacing: Theme.spacingM

                    Repeater {
                        model: root.usage !== null ? root.windowKeys : []
                        delegate: Column {
                            id: winRow
                            required property var modelData
                            readonly property var win: root.usage && root.usage[modelData] ? root.usage[modelData] : null
                            readonly property int winPct: {
                                const p = root.pct(modelData)
                                return p !== null ? p : -1
                            }
                            width: parent.width
                            spacing: Theme.spacingXXS
                            visible: win !== null

                            Item {
                                width: parent.width
                                height: winLabel.implicitHeight
                                StyledText {
                                    id: winLabel
                                    anchors.left: parent.left
                                    text: root.windowLabel(winRow.modelData)
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                }
                                StyledText {
                                    anchors.right: parent.right
                                    text: winRow.winPct >= 0 ? winRow.winPct + "%" : "--"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: root.statusColor(winRow.winPct >= 0 ? winRow.winPct : null)
                                }
                            }

                            StyledRect {
                                width: parent.width
                                height: 6
                                radius: 3
                                color: Theme.surfaceContainerHigh
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: parent.width * Math.max(0, Math.min(100, winRow.winPct)) / 100
                                    radius: 3
                                    color: root.statusColor(winRow.winPct >= 0 ? winRow.winPct : null)
                                }
                            }

                            Item {
                                width: parent.width
                                height: resetText.implicitHeight
                                StyledText {
                                    id: resetText
                                    anchors.left: parent.left
                                    text: "resets in " + root.fmtCountdown(winRow.win ? winRow.win.resetsAt : null)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                StyledText {
                                    anchors.right: parent.right
                                    text: root.fmtResetAbs(winRow.win ? winRow.win.resetsAt : null)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }

                    StyledRect {
                        width: parent.width
                        height: 1
                        color: Theme.outlineVariant
                    }

                    Item {
                        width: parent.width
                        height: balLabel.implicitHeight
                        StyledText {
                            id: balLabel
                            anchors.left: parent.left
                            text: "Zen balance"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                        }
                        StyledText {
                            anchors.right: parent.right
                            text: root.balanceText()
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: root.balance !== null ? Font.Medium : Font.Normal
                            color: root.balanceColor()
                        }
                    }

                    StyledText {
                        visible: root.balance !== null
                        width: parent.width
                        text: "as of " + root.fmtAge(root.balance ? root.balance.fetchedAt : 0)
                            + (root.balanceError !== "" ? " (refresh failing)" : "")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: root.lastError !== ""
                        width: parent.width
                        text: root.errorText()
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
