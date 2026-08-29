import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "lu15ggtz.netscan"
  ipcTarget: "lu15ggtz.netscan"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accentColor: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string enginePath: Qt.resolvedUrl("bin/netscan-engine").toString().replace(/^file:\/\//, "")

  // Network state
  property string iface: ""
  property string subnet: ""
  property string gateway: ""
  property string localIp: ""
  property int deviceCount: 0
  property var devices: []
  property bool isScanning: false

  // Selected device and port inspection state
  property int selectedIndex: 0
  property string selectedIp: (devices.length > selectedIndex && selectedIndex >= 0) ? devices[selectedIndex].ip : ""
  property var selectedDevice: (devices.length > selectedIndex && selectedIndex >= 0) ? devices[selectedIndex] : null
  property bool isScanningPorts: false
  property bool portScanDone: false
  property bool portScanHostUp: false
  property string portScanLatency: ""
  property var currentPorts: []

  // Buffers for Process output
  property string scanBuffer: ""
  property string nmapBuffer: ""
  property string copyTarget: ""
  property string openUrl: ""
  property bool showCopiedFeedback: false

  function triggerScan() {
    if (isScanning) return
    isScanning = true
    scanBuffer = ""
    scanProc.running = true
  }

  function triggerPortScan(ip) {
    if (isScanningPorts || !ip) return
    isScanningPorts = true
    portScanDone = false
    currentPorts = []
    nmapBuffer = ""
    selectedIp = ip
    nmapProc.command = [enginePath, "ports", ip]
    nmapProc.running = true
  }

  function copyToClipboard(text) {
    if (!text) return
    copyTarget = text
    copyProc.running = true
    showCopiedFeedback = true
    copiedTimer.restart()
  }

  function openInBrowser(url) {
    if (!url) return
    openUrl = url
    browserProc.running = true
  }

  function selectDevice(idx) {
    if (idx < 0 || idx >= devices.length) return
    selectedIndex = idx
    portScanDone = false
    currentPorts = []
  }

  function nextDevice() {
    if (devices.length === 0) return
    var next = (selectedIndex + 1) % devices.length
    selectDevice(next)
  }

  function prevDevice() {
    if (devices.length === 0) return
    var prev = (selectedIndex - 1 + devices.length) % devices.length
    selectDevice(prev)
  }

  onOpenedChanged: {
    if (opened) {
      if (devices.length === 0) {
        triggerScan()
      }
    }
  }

  // ------------------------------------------------------------- Processes

  Process {
    id: scanProc
    command: [root.enginePath, "scan"]
    stdout: SplitParser {
      onRead: function(data) {
        root.scanBuffer += data
      }
    }
    onExited: function(exitCode) {
      root.isScanning = false
      if (exitCode === 0 && root.scanBuffer.length > 0) {
        try {
          var res = JSON.parse(root.scanBuffer)
          if (res.status === "ok") {
            root.iface = res.iface
            root.subnet = res.subnet
            root.gateway = res.gateway
            root.localIp = res.localIp
            root.deviceCount = res.deviceCount
            root.devices = res.devices || []
            if (root.selectedIndex >= root.devices.length) root.selectedIndex = 0
          }
        } catch (e) {
          console.log("[netscan] Error parsing scan JSON:", e)
        }
      }
      root.scanBuffer = ""
    }
  }

  Process {
    id: nmapProc
    command: [root.enginePath, "ports", root.selectedIp]
    stdout: SplitParser {
      onRead: function(data) {
        root.nmapBuffer += data
      }
    }
    onExited: function(exitCode) {
      root.isScanningPorts = false
      if (exitCode === 0 && root.nmapBuffer.length > 0) {
        try {
          var res = JSON.parse(root.nmapBuffer)
          if (res.status === "ok") {
            root.currentPorts = res.ports || []
            root.portScanDone = true
            root.portScanHostUp = res.hostUp
            root.portScanLatency = res.latency
          }
        } catch (e) {
          console.log("[netscan] Error parsing nmap JSON:", e)
        }
      }
      root.nmapBuffer = ""
    }
  }

  Process {
    id: copyProc
    command: ["wl-copy", root.copyTarget]
  }

  Process {
    id: browserProc
    command: ["xdg-open", root.openUrl]
  }

  Timer {
    id: copiedTimer
    interval: 1800
    onTriggered: root.showCopiedFeedback = false
  }

  // ------------------------------------------------------------- Bar Button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uDB81\uDEF3" // 󰛳 Lan / Devices icon
    tooltipText: root.deviceCount > 0
      ? "Network Scanner · " + root.deviceCount + " hosts online"
      : "Network Scanner (arp-scan & nmap)"

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.triggerScan()
        return
      }
      root.toggle()
    }
  }

  // ------------------------------------------------------------- Floating Panel

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(430))
    contentHeight: popup.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (dy > 0) root.nextDevice()
        else if (dy < 0) root.prevDevice()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.triggerScan()
        else if (t === "s" || t === "S" || t === "p" || t === "P") {
          if (root.selectedIp) root.triggerPortScan(root.selectedIp)
        } else if (t === "c" || t === "C") {
          if (root.selectedIp) root.copyToClipboard(root.selectedIp)
        }
      }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // -------------------------------------------------------- HERO HEADER
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          Text {
            id: heroIcon
            text: "\uDB81\uDEF3" // 󰛳
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: heroActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Local Network"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.isScanning
                ? "SCANNING SUBNET VIA ARP..."
                : (root.deviceCount + " DEVICES ONLINE \u00b7 " + (root.subnet || "LOCALNET"))
              color: root.isScanning ? root.accentColor : Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }
          }

          RowLayout {
            id: heroActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              id: refreshBtn
              iconText: root.isScanning ? "󰑐" : "󰚌"
              tooltipText: "Rescan network (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconSize: Style.font.subtitle * 1.3
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(3)
              enabled: !root.isScanning
              onClicked: root.triggerScan()
            }
          }
        }

        // Subnet info pill
        BorderSurface {
          width: parent.width
          implicitHeight: ifaceText.implicitHeight + Style.space(8)
          color: Style.hoverFillFor(root.foreground, root.accentColor)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accentColor)
          radius: Style.cornerRadius

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)

            Text {
              id: ifaceText
              text: "iface: " + (root.iface || "—") + "  \u00b7  gw: " + (root.gateway || "—")
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.foreground, 1.3)
              Layout.fillWidth: true
              elide: Text.ElideRight
            }

            Text {
              visible: root.showCopiedFeedback
              text: "✓ IP Copied"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.accentColor
            }
          }
        }

        PanelSectionHeader {
          text: "Discovered Hosts (arp-scan)"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // -------------------------------------------------------- DEVICES LIST
        ListView {
          id: deviceList
          width: parent.width
          height: Math.min(contentHeight, Style.space(220))
          spacing: Style.space(3)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.devices
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: CursorSurface {
            id: devRow
            required property var modelData
            required property int index

            readonly property bool isSelected: root.selectedIndex === devRow.index

            width: ListView.view.width
            implicitHeight: rowContent.implicitHeight + Style.space(8)
            hasCursor: devRow.isSelected
            current: devRow.modelData.isSelf || devRow.modelData.isGateway
            foreground: root.foreground

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectDevice(devRow.index)
            }

            RowLayout {
              id: rowContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              // Device category icon
              Text {
                text: devRow.modelData.icon || "󰛳"
                color: devRow.isSelected ? root.accentColor : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                Layout.alignment: Qt.AlignVCenter
              }

              // IP and Vendor
              Column {
                Layout.fillWidth: true
                spacing: Style.space(1)

                RowLayout {
                  spacing: Style.space(6)

                  Text {
                    text: devRow.modelData.ip
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    visible: devRow.modelData.isGateway
                    text: "[GW]"
                    color: root.accentColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption - 1
                    font.bold: true
                  }

                  Text {
                    visible: devRow.modelData.isSelf
                    text: "[YOU]"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption - 1
                    font.bold: true
                  }
                }

                Text {
                  text: devRow.modelData.vendor || devRow.modelData.category
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              // Selection indicator
              Text {
                text: devRow.isSelected ? "󰅀" : "󰅂"
                color: devRow.isSelected ? root.accentColor : Qt.darker(root.foreground, 2.0)
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                Layout.alignment: Qt.AlignVCenter
              }
            }
          }
        }

        // Empty state
        Text {
          visible: root.devices.length === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(16)
          bottomPadding: Style.space(16)
          text: root.isScanning ? "Scanning local subnet via ARP\u2026" : "No devices responded to ARP scan"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.6
        }

        // -------------------------------------------------------- SELECTED DEVICE DETAILS (NMAP DRAWER)
        Item {
          visible: root.selectedDevice !== null
          width: parent.width
          implicitHeight: detailBox.implicitHeight

          BorderSurface {
            id: detailBox
            width: parent.width
            implicitHeight: detailColumn.implicitHeight + Style.space(16)
            color: Style.hoverFillFor(root.foreground, root.accentColor)
            borderSpec: Border.controlSpec("hover-cursor", root.foreground, root.accentColor)
            radius: Style.cornerRadius

            Column {
              id: detailColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.topMargin: Style.space(8)
              spacing: Style.space(8)

              // Top Row: IP + Badges & Action Buttons
              RowLayout {
                width: parent.width

                RowLayout {
                  spacing: Style.space(6)
                  Layout.alignment: Qt.AlignVCenter

                  Text {
                    text: root.selectedDevice ? root.selectedDevice.ip : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Text {
                    visible: root.selectedDevice && root.selectedDevice.isGateway
                    text: "[GW]"
                    color: root.accentColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption - 1
                    font.bold: true
                  }

                  Text {
                    visible: root.selectedDevice && root.selectedDevice.isSelf
                    text: "[YOU]"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption - 1
                    font.bold: true
                  }
                }

                Item { Layout.fillWidth: true } // Spacer

                // Action buttons: Copy IP & Nmap Port Scan
                RowLayout {
                  spacing: Style.space(6)
                  Layout.alignment: Qt.AlignVCenter

                  Button {
                    text: "Copy"
                    iconText: "󰆏"
                    tooltipText: "Copy IP (c)"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(3)
                    bordered: true
                    onClicked: if (root.selectedIp) root.copyToClipboard(root.selectedIp)
                  }

                  Button {
                    id: scanNmapBtn
                    text: root.isScanningPorts ? "Scanning…" : "Scan (Nmap)"
                    iconText: root.isScanningPorts ? "󰑐" : "󱂛"
                    tooltipText: "Probe open ports on this host (s)"
                    foreground: root.accentColor
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    bordered: true
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(3)
                    enabled: !root.isScanningPorts
                    onClicked: if (root.selectedIp) root.triggerPortScan(root.selectedIp)
                  }
                }
              }

              // Metadata Info Rows (Full Width - never cut off)
              Column {
                width: parent.width
                spacing: Style.space(2)

                RowLayout {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: "MAC:"
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    text: root.selectedDevice ? root.selectedDevice.mac : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    text: "\u00b7"
                    color: Qt.darker(root.foreground, 1.8)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    text: root.selectedDevice ? root.selectedDevice.category : ""
                    color: root.accentColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }
                }

                RowLayout {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.selectedDevice && root.selectedDevice.vendor && root.selectedDevice.vendor !== "Locally Administered" && root.selectedDevice.vendor !== "Unknown Vendor"

                  Text {
                    text: "Vendor:"
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    text: root.selectedDevice ? root.selectedDevice.vendor : ""
                    color: Qt.darker(root.foreground, 1.2)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }
                }
              }

              // NMAP RESULTS SECTION
              Item {
                visible: root.isScanningPorts || root.portScanDone
                width: parent.width
                implicitHeight: nmapResultsColumn.implicitHeight

                Column {
                  id: nmapResultsColumn
                  width: parent.width
                  spacing: Style.space(4)

                  PanelSeparator { width: parent.width }

                  RowLayout {
                    width: parent.width

                    Text {
                      text: root.isScanningPorts
                        ? "PROBING SERVICES (NMAP)..."
                        : ("OPEN PORTS (" + root.currentPorts.length + ") \u00b7 " + root.portScanLatency)
                      color: root.isScanningPorts ? root.accentColor : Qt.darker(root.foreground, 1.3)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption - 1
                      font.bold: true
                      Layout.fillWidth: true
                    }
                  }

                  // Ports Table
                  Repeater {
                    model: root.currentPorts

                    delegate: Item {
                      required property var modelData
                      width: parent.width
                      implicitHeight: portRow.implicitHeight + Style.space(2)

                      RowLayout {
                        id: portRow
                        anchors.fill: parent
                        spacing: Style.space(8)

                        Text {
                          text: modelData.port
                          color: root.accentColor
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                          Layout.preferredWidth: Style.space(70)
                        }

                        Text {
                          text: modelData.service + (modelData.version ? (" (" + modelData.version + ")") : "")
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                          Layout.fillWidth: true
                        }

                        // If web service, show Quick Open button
                        Button {
                          visible: modelData.portNum === 80 || modelData.portNum === 8080 || modelData.portNum === 443
                          iconText: "󰖟"
                          tooltipText: "Open in browser"
                          foreground: root.foreground
                          fontFamily: root.fontFamily
                          fontSize: Style.font.caption
                          horizontalPadding: Style.space(4)
                          verticalPadding: Style.space(2)
                          onClicked: {
                            var proto = modelData.portNum === 443 ? "https://" : "http://"
                            var portSuffix = (modelData.portNum === 80 || modelData.portNum === 443) ? "" : (":" + modelData.portNum)
                            root.openInBrowser(proto + root.selectedIp + portSuffix)
                          }
                        }
                      }
                    }
                  }

                  // No open ports feedback
                  Text {
                    visible: root.portScanDone && root.currentPorts.length === 0
                    text: "No open common ports discovered on this host."
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    topPadding: Style.space(4)
                  }
                }
              }
            }
          }
        }

        // -------------------------------------------------------- FOOTER HINTS
        RowLayout {
          width: parent.width
          Text {
            text: "j/k: navigate  \u00b7  s: scan ports  \u00b7  r: refresh  \u00b7  esc: close"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption - 1
            color: Qt.darker(root.foreground, 1.7)
            Layout.alignment: Qt.AlignHCenter
          }
        }
      }
    }
  }
}
