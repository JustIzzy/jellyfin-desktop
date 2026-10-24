import QtQuick
import Konvergo 1.0
import QtWebEngine
import QtWebChannel
import QtQuick.Window
import QtQuick.Controls
import Qt.labs.platform as Labs

Window
{
  id: mainWindow
  title: "Jellyfin Desktop"
  objectName: "mainWindow"
  width: 1280
  height: 720
  minimumWidth: 213
  minimumHeight: 120
  visible: true
  color: "#000000"

  // Properties previously from KonvergoWindow
  property bool webDesktopMode: true
  property bool showDebugLayer: false
  property string debugInfo: ""
  property string videoInfo: ""
  property string webUrl: ""

  property bool showSystemTrayIcon: webDesktopMode && components.system.isWindows &&
                                    components.settings.windowsTrayIcon

  signal reloadWebClient()

  Component.onCompleted: {
    if (components && components.settings) {
      webUrl = components.settings.getWebClientUrl(webDesktopMode)
    }
  }

  onClosing: function(close) {
    if (showSystemTrayIcon) {
      // Minimize to tray on close.
      close.accepted = false
      mainWindow.hide()
    }
  }

  // Borderless-maximised instead of true fullscreen.
  //
  // On hybrid-GPU (Optimus) systems, true Window.FullScreen lets Windows hand the
  // window to a direct-scanout / independent-flip path. Qt's OpenGL FBO layer -
  // which is where mpv draws via the render API - does not survive that handoff,
  // so the video node stops being composited while the transparent web UI still
  // paints. Symptom: audio plays, UI works, video is invisible until the user
  // leaves fullscreen. Borderless-maximised keeps DWM compositing and renders
  // correctly, while looking identical to the user.
  property bool fakeFullScreen: false

  function _enterFakeFullScreen() {
    if (fakeFullScreen)
      return
    fakeFullScreen = true
    mainWindow.flags |= Qt.FramelessWindowHint
    visibility = Window.Maximized
  }

  function _leaveFakeFullScreen() {
    if (!fakeFullScreen)
      return
    fakeFullScreen = false
    mainWindow.flags &= ~Qt.FramelessWindowHint
    visibility = Window.Windowed
  }

  function toggleFullscreen() {
    if (fakeFullScreen)
      _leaveFakeFullScreen()
    else
      _enterFakeFullScreen()
  }

  function toggleDebug() {
    showDebugLayer = !showDebugLayer
  }

  function setFullScreen(enable) {
    if (enable)
      _enterFakeFullScreen()
    else
      _leaveFakeFullScreen()
  }

  function minimizeWindow() {
    if (visibility !== Window.FullScreen && !fakeFullScreen)
      visibility = Window.Minimized
  }

  function restoreWindow() {
    mainWindow.show()
    mainWindow.raise()
    mainWindow.requestActivate()
  }

  function runWebAction(action)
  {
    if (mainWindow.webDesktopMode)
      web.triggerWebAction(action)
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut:
    {
      if (components.system.isMacos) return "Ctrl+Meta+F"
      return "F11"
    }
    onTriggered: mainWindow.toggleFullscreen()
  }

  Action
  {
    shortcut: "Alt+Return"
    enabled:
    {
      if (mainWindow.webDesktopMode && components.system.isWindows)
        return true;
      return false;
    }
    onTriggered: mainWindow.toggleFullscreen()
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: StandardKey.Close
    onTriggered: mainWindow.close()
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: {
      if (components.system.isMacos) return "Ctrl+M";
      return "Meta+Down";
    }
    onTriggered: mainWindow.minimizeWindow()
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: components.system.isWindows ? "Ctrl+Q" : StandardKey.Quit
    onTriggered: Qt.quit()
  }

  Action
  {
    shortcut: "Ctrl+Shift+D"
    enabled: mainWindow.webDesktopMode
    onTriggered: mainWindow.toggleDebug()
  }

  Action
  {
    shortcut: StandardKey.Copy
    onTriggered: runWebAction(WebEngineView.Copy)
    id: action_copy
  }

  Action
  {
    shortcut: StandardKey.Cut
    onTriggered: runWebAction(WebEngineView.Cut)
    id: action_cut
  }

  Action
  {
    shortcut: StandardKey.Paste
    onTriggered: runWebAction(WebEngineView.Paste)
    id: action_paste
  }

  Action
  {
    shortcut: StandardKey.SelectAll
    onTriggered: runWebAction(WebEngineView.SelectAll)
    id: action_selectall
  }

  Action
  {
    shortcut: StandardKey.Undo
    onTriggered: runWebAction(WebEngineView.Undo)
    id: action_undo
  }

  Action
  {
    shortcut: StandardKey.Redo
    onTriggered: runWebAction(WebEngineView.Redo)
    id: action_redo
  }

  Action
  {
    shortcut: StandardKey.Back
    onTriggered: runWebAction(WebEngineView.Back)
    id: action_back
  }

  Action
  {
    shortcut: StandardKey.Forward
    onTriggered: runWebAction(WebEngineView.Forward)
    id: action_forward
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: "Ctrl+0"
    onTriggered: web.zoomFactor = 1.0
  }

  WebChannel
  {
    id: webChannelObject
  }

  Binding
  {
    target: web
    property: "zoomFactor"
    value: 1.0
    when: !components.settings.allowBrowserZoom()
  }


  // FIX: force the WebEngineView's compositor surface to be recreated when the
  // player opens.
  //
  // The page is CSS-transparent (backgroundColor #00000000, every DOM layer
  // rgba(0,0,0,0)), but on this setup QtWebEngine's compositor layer is still
  // composited opaquely until its surface is recreated. That opaque layer sits
  // at z:100 over the mpv video item, so video renders correctly but is never
  // visible. Any window-state change (e.g. toggling fullscreen) recreates the
  // surface and the video appears - which is the long-standing "toggle
  // fullscreen to see the picture" workaround. Hiding/showing the view forces
  // the same recreation without touching window state.
  MpvVideoItem
  {
    id: video
    objectName: "video"
    enabled: true

    // FIX: fill the content item exactly.
    //
    // Previously this set anchors.left + anchors.right AND explicit width/height
    // bindings, with no anchors.bottom. left+right anchors already determine
    // width, so the explicit width binding conflicts with them, and height was
    // left to a binding with no matching bottom anchor. The result was a video
    // surface whose geometry did not match the window's content area: the
    // picture rendered offset (pushed down/right, cropped, black bands) in any
    // state where the client area is smaller than the screen - i.e. windowed
    // and maximised. In true fullscreen the client area happens to equal the
    // screen, the offset collapses to zero, and the picture looks correct -
    // which is why toggling fullscreen "fixed" playback.
    anchors.fill: parent

    Component.onCompleted: {
      console.log("MpvVideoItem size:", width, "x", height, "visible:", visible)
    }
  }

  WebEngineView
  {
    id: web
    objectName: "web"
    width: mainWindow.width
    height: mainWindow.height
    z: 100
    // Qt 6.9.3: a fully-transparent base background (alpha 0) is not composited
    // transparently - the surface stays opaque over the mpv item. A real colour
    // with alpha 1/255 is visually identical and does composite. Set here at
    // construction: assigning backgroundColor at runtime trips a CHECK inside
    // Qt6WebEngineCore and kills the process (0x80000003).
    backgroundColor: "#01000000"

    // this is needed to prevent intermittent(?) black screens when unminizing
    // or resumsing from suspend (linux/{x11/wayland}, possibly others).
    layer.enabled: true

    webChannel: webChannelObject
    settings.errorPageEnabled: false
    settings.localContentCanAccessRemoteUrls: true
    settings.localContentCanAccessFileUrls: true
    settings.allowRunningInsecureContent: true
    settings.playbackRequiresUserGesture: false
    profile.httpUserAgent: components.system.getUserAgent()
    profile.httpCacheType: WebEngineProfile.DiskHttpCache
    url: mainWindow.webUrl
    focus: true
    property string currentHoveredUrl: ""
    onLinkHovered: function(hoveredUrl)
    {
      web.currentHoveredUrl = hoveredUrl;
    }
    profile.persistentCookiesPolicy: WebEngineProfile.AllowPersistentCookies
    profile.offTheRecord: false
    profile.storageName: "JellyfinDesktopStorage"

    Component.onCompleted:
    {
      console.log("WebEngineView size:", width, "x", height, "backgroundColor:", backgroundColor)
      forceActiveFocus()
      mainWindow.reloadWebClient.connect(reload)

      // Handle CSP workaround from C++
      components.system.pageContentReady.connect(function(html, finalUrl, hadCSP) {
        if (hadCSP) {
          console.log("CSP workaround: navigating to", finalUrl);
          web.url = finalUrl;
        }
      })

      var nativeshell =
      {
        sourceCode: components.system.getNativeShellScript(),
        injectionPoint: WebEngineScript.DocumentCreation,
        worldId: WebEngineScript.MainWorld
      }

      web.profile.userScripts.collection = [ nativeshell ];
    }

    onLoadingChanged: function(loadingInfo)
    {
      // we use a timer here to switch to the webview since
      // it take a few moments for the webview to render
      // after it has loaded.
      //
      if (loadingInfo.status == WebEngineView.LoadStartedStatus)
      {
        console.log("WebEngineLoadRequest starting: " + loadingInfo.url);
      }
      else if (loadingInfo.status == WebEngineView.LoadSucceededStatus)
      {
        console.log("WebEngineLoadRequest success: " + loadingInfo.url);
      }
      else if (loadingInfo.status == WebEngineView.LoadFailedStatus)
      {
        console.log("WebEngineLoadRequest failure: " + loadingInfo.url + " error code: " + loadingInfo.errorCode);
        errorLabel.visible = true
        errorLabel.text = "Error loading client, this is bad and should not happen<br>" +
                          "You can try to <a href='reload'>reload</a> or head to our <a href='http://jellyfin.org'>support page</a><br><br>Actual Error: <pre>" +
                          loadingInfo.errorString + " [" + loadingInfo.errorCode + "]</pre><br><br>" +
                          "Provide the <a target='_blank' href='file://"+ components.system.logFilePath + "'>logfile</a> as well."
      }
    }

    onNewWindowRequested:
    {
      if (request.userInitiated)
      {
        console.log("Opening external URL: " + web.currentHoveredUrl)
        components.system.openExternalUrl(web.currentHoveredUrl)
      }
    }

    onFullScreenRequested:
    {
      console.log("Request fullscreen: " + request.toggleOn)
      mainWindow.setFullScreen(request.toggleOn)
      request.accept()
    }

    onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID)
    {
      components.system.jsLog(level, sourceID + ":" + lineNumber + " " + message);
    }

    onCertificateError: function(error)
    {
      console.log(error.url + " :" + error.description + error.error)
      if (components.settings.ignoreSSLErrors()) {
        error.acceptCertificate()
      }
    }
  }

  Text
  {
    id: errorLabel
    z: 5
    anchors.centerIn: parent
    color: "#999999"
    linkColor: "#a85dc3"
    text: "Generic error"
    font.pixelSize: 32
    font.bold: true
    visible: false
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.StyledText
    onLinkActivated:
    {
      if (url == "reload")
      {
        errorLabel.visible = false
        web.reload()
      }
      else
      {
        Qt.openUrlExternally(url)
      }
    }
  }


  Rectangle
  {
    id: debug
    color: "black"
    z: 10
    anchors.centerIn: parent
    width: parent.width
    height: parent.height
    opacity: 0.7
    visible: mainWindow.showDebugLayer

    Text
    {
      id: debugLabel
      width: (parent.width - 50) / 2
      height: parent.height - 25
      anchors.left: parent.left
      anchors.leftMargin: 64
      anchors.top: parent.top
      anchors.topMargin: 54
      anchors.bottomMargin: 54
      color: "white"
      font.pixelSize: Math.round(height / 65)
      wrapMode: Text.WrapAnywhere

      function windowDebug()
      {
        var dbg = mainWindow.debugInfo + "Window and web\n";
        dbg += "  Window size: " + parent.width + "x" + parent.height + " - " + web.width + "x" + web.height + "\n";
        dbg += "  DevicePixel ratio: " + Screen.devicePixelRatio + "\n";

        return dbg;
      }

      text: windowDebug()
    }

    Text
    {
      id: videoLabel
      width: (parent.width - 50) / 2
      height: parent.height - 25
      anchors.right: parent.right
      anchors.left: debugLabel.right
      anchors.rightMargin: 64
      anchors.top: parent.top
      anchors.topMargin: 54
      anchors.bottomMargin: 54
      color: "white"
      font.pixelSize: Math.round(height / 65)
      wrapMode: Text.WrapAnywhere

      text: mainWindow.videoInfo
    }
  }

  property QtObject webChannel: web.webChannel

  Labs.SystemTrayIcon {
    visible: showSystemTrayIcon
    icon.source: "qrc:/images/icon.png"
    tooltip: "Jellyfin Desktop"

    onActivated: function(reason) {
      if (reason === Labs.SystemTrayIcon.Context) {
        // Right click: open context menu
        contextMenu.open()
        components.window.setCursorVisibility(true)
      } else {
        // All other clicks: restore window
        restoreWindow()
      }
    }

    menu: Labs.Menu {
      id: contextMenu
      Labs.MenuItem {
        text: qsTr("Restore")
        onTriggered: restoreWindow()
      }
      Labs.MenuSeparator {}
      Labs.MenuItem {
        text: qsTr("Quit")
        onTriggered: Qt.quit()
      }
    }
  }
}
