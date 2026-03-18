//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

/// Custom OSD window matching the macOS Tahoe (26+) pill-shaped volume/brightness indicator.
/// Supports vertical (left/right) and horizontal (top/bottom) orientations.
/// Interactive: click or drag to set brightness/volume directly.
/// Uses NSGlassEffectView + NSGlassEffectContainerView on macOS 26+ for native Liquid Glass.
@available(macOS 11.0, *)
class TahoeOSDWindow {

  // MARK: - Layout Constants

  private static let pillShort: CGFloat = 36
  private static let pillLong: CGFloat = 200
  private static let cornerRadius: CGFloat = 18
  private static let iconSize: CGFloat = 16
  private static let iconEdgePadding: CGFloat = 10
  private static let screenEdgePadding: CGFloat = 16

  // MARK: - Animation Constants

  private static let fadeInDuration: TimeInterval = 0.18
  private static let fadeOutDuration: TimeInterval = 0.35
  private static let fillAnimationDuration: TimeInterval = 0.15
  private static let dismissDelay: TimeInterval = 1.5
  private static let interactiveDismissDelay: TimeInterval = 1.0

  // MARK: - DDC Throttle Constants

  private static let ddcWriteInterval: TimeInterval = 0.1 // Max 10 writes/sec

  // MARK: - Shared State

  private static var windows: [CGDirectDisplayID: TahoeOSDWindow] = [:]

  /// Remove cached OSD windows for displays that are no longer connected.
  static func cleanUpDisconnectedDisplays() {
    let connectedIDs = Set(NSScreen.screens.compactMap { $0.displayID })
    for displayID in windows.keys where !connectedIDs.contains(displayID) {
      windows[displayID]?.panel.orderOut(nil)
      windows.removeValue(forKey: displayID)
    }
  }

  // MARK: - Fill View (legacy fallback only)

  private class FillView: NSView {
    var fillColor = NSColor.white.withAlphaComponent(0.55)
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
      fillColor.setFill()
      bounds.fill()
    }
  }

  // MARK: - Panel subclass — must be key-capable for cursor rects to work

  private class OSDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }

  // MARK: - Interactive Hit View — handles mouse events + cursor

  private class InteractiveView: NSView {
    weak var osdWindow: TahoeOSDWindow?
    private var trackingArea: NSTrackingArea?
    private var cursorPushed = false

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let existing = trackingArea {
        removeTrackingArea(existing)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways],
        owner: self,
        userInfo: nil
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      if !cursorPushed {
        NSCursor.pointingHand.push()
        cursorPushed = true
      }
      // Keep OSD visible while hovered
      osdWindow?.handleMouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
      if cursorPushed {
        NSCursor.pop()
        cursorPushed = false
      }
      // Resume dismiss countdown after mouse leaves
      osdWindow?.handleMouseExited()
    }

    // Accept the very first click without requiring the window to be key first
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      osdWindow?.handleMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
      osdWindow?.handleMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
      osdWindow?.handleMouseUp()
    }

    deinit {
      if cursorPushed {
        NSCursor.pop()
      }
    }
  }

  // MARK: - Instance Properties

  private let panel: OSDPanel
  private let iconView: NSImageView
  private let interactiveView: InteractiveView
  private let displayID: CGDirectDisplayID
  private var dismissTimer: Timer?
  private var isHorizontal: Bool = false
  private var currentCommand: Command = .brightness
  private var isDragging: Bool = false
  private var isHovered: Bool = false
  private var lastDDCWriteTime: TimeInterval = 0
  private var pendingDDCValue: Float?
  private var ddcThrottleTimer: Timer?

  // Fill indicator (used on both Tahoe and legacy)
  private var fillView: FillView?

  // Legacy fallback (pre-26)
  private var effectView: NSVisualEffectView?

  // MARK: - Public Interface

  static func showOsd(displayID: CGDirectDisplayID, command: Command, value: Float, maxValue: Float = 1) {
    let normalizedValue = maxValue > 0 ? min(max(value / maxValue, 0), 1) : 0
    let icon = self.iconInfo(for: command, value: normalizedValue)
    let work = {
      let osd = self.getOrCreate(for: displayID)
      osd.currentCommand = command
      osd.applyOrientation()
      osd.update(iconName: icon.name, variableValue: icon.variableValue, value: normalizedValue)
      osd.present()
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async { work() } }
  }

  static func showOsdDisabled(displayID: CGDirectDisplayID, iconName: String) {
    let work = {
      let osd = self.getOrCreate(for: displayID)
      osd.applyOrientation()
      osd.update(iconName: iconName, variableValue: nil, value: 0)
      osd.present()
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async { work() } }
  }

  static func popEmpty(displayID: CGDirectDisplayID, command: Command) {
    let work = {
      let osd = self.getOrCreate(for: displayID)
      let icon = self.iconInfo(for: command, value: 0)
      osd.currentCommand = command
      osd.applyOrientation()
      osd.update(iconName: icon.name, variableValue: icon.variableValue, value: 0)
      osd.present(autoDismissDelay: 0)
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async { work() } }
  }

  // MARK: - Icon Selection

  /// Returns (symbolName, variableValue) for the given command and level.
  /// Volume uses a single symbol with variable value so the speaker body never changes size.
  private static func iconInfo(for command: Command, value: Float) -> (name: String, variableValue: Double?) {
    switch command {
    case .audioSpeakerVolume:
      // Always use speaker.wave.3.fill with variable value so the icon frame never changes.
      // variableValue 0 = all waves dimmed (muted look), 1 = all waves lit.
      return ("speaker.wave.3.fill", Double(max(0, value)))
    case .audioMuteScreenBlank:
      return ("speaker.wave.3.fill", 0)
    case .contrast:
      return ("circle.lefthalf.fill", nil)
    default:
      return ("sun.max.fill", nil)
    }
  }

  // MARK: - Window Management

  private static func getOrCreate(for displayID: CGDirectDisplayID) -> TahoeOSDWindow {
    if let existing = windows[displayID] {
      return existing
    }
    let osd = TahoeOSDWindow(displayID: displayID)
    windows[displayID] = osd
    return osd
  }

  // MARK: - Orientation

  private static func currentIsHorizontal() -> Bool {
    let position = OSDPosition(rawValue: prefs.integer(forKey: PrefKey.osdPosition.rawValue)) ?? .left
    return position == .top || position == .bottom
  }

  private var pillWidth: CGFloat { isHorizontal ? Self.pillLong : Self.pillShort }
  private var pillHeight: CGFloat { isHorizontal ? Self.pillShort : Self.pillLong }

  private func applyOrientation() {
    let newHorizontal = Self.currentIsHorizontal()
    guard newHorizontal != isHorizontal else { return }
    isHorizontal = newHorizontal

    let w = pillWidth
    let h = pillHeight
    let pillFrame = NSRect(x: 0, y: 0, width: w, height: h)

    // Resize the root (panel.contentView) and all children
    panel.contentView?.frame = pillFrame
    for subview in panel.contentView?.subviews ?? [] {
      // Resize glass, effect, and interactive views to full pill
      // (fill view is resized separately in update())
      if subview !== fillView {
        subview.frame = pillFrame
      }
    }
    effectView?.frame = pillFrame
    interactiveView.frame = pillFrame

    if isHorizontal {
      iconView.frame = NSRect(
        x: Self.iconEdgePadding,
        y: (h - Self.iconSize) / 2,
        width: Self.iconSize,
        height: Self.iconSize
      )
    } else {
      iconView.frame = NSRect(
        x: (w - Self.iconSize) / 2,
        y: Self.iconEdgePadding,
        width: Self.iconSize,
        height: Self.iconSize
      )
    }
  }

  // MARK: - Initialization

  private init(displayID: CGDirectDisplayID) {
    self.displayID = displayID
    self.isHorizontal = Self.currentIsHorizontal()

    let w: CGFloat = isHorizontal ? Self.pillLong : Self.pillShort
    let h: CGFloat = isHorizontal ? Self.pillShort : Self.pillLong
    let pillFrame = NSRect(x: 0, y: 0, width: w, height: h)

    // Panel
    panel = OSDPanel(
      contentRect: pillFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.ignoresMouseEvents = false
    panel.acceptsMouseMovedEvents = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hasShadow = true
    panel.animationBehavior = .none
    panel.alphaValue = 0
    panel.isReleasedWhenClosed = false

    // Icon
    let iconFrame: NSRect
    if isHorizontal {
      iconFrame = NSRect(x: Self.iconEdgePadding, y: (h - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
    } else {
      iconFrame = NSRect(x: (w - Self.iconSize) / 2, y: Self.iconEdgePadding, width: Self.iconSize, height: Self.iconSize)
    }
    iconView = NSImageView(frame: iconFrame)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = .white

    // Interactive overlay
    interactiveView = InteractiveView(frame: pillFrame)
    interactiveView.osdWindow = self

    // Build view hierarchy depending on macOS version
    if #available(macOS 26.0, *) {
      setupTahoeGlass(pillFrame: pillFrame)
    } else {
      setupLegacyVisualEffect(pillFrame: pillFrame)
    }
  }

  // MARK: - Tahoe Glass Setup (macOS 26+)

  @available(macOS 26.0, *)
  private func setupTahoeGlass(pillFrame: NSRect) {
    let w = pillFrame.width
    let h = pillFrame.height

    // Glass background: clear style for a lighter, more transparent glass
    let glass = NSGlassEffectView()
    glass.frame = pillFrame
    glass.cornerRadius = Self.cornerRadius
    glass.style = .clear

    // Fill indicator: placed inside the glass contentView so it renders
    // through the glass refraction — no separate clip container needed
    let glassContent = NSView(frame: pillFrame)
    let fill = FillView(frame: NSRect(x: 0, y: 0, width: isHorizontal ? 0 : w, height: isHorizontal ? h : 0))
    fill.fillColor = NSColor.white.withAlphaComponent(0.12)
    self.fillView = fill
    glassContent.addSubview(fill)
    glass.contentView = glassContent

    // Root: glass (contains fill inside), icon + interactive on top
    let root = NSView(frame: pillFrame)
    root.wantsLayer = true
    root.addSubview(glass)
    root.addSubview(iconView)
    root.addSubview(interactiveView)
    panel.contentView = root

    // Reduce the backdrop blur intensity applied by NSGlassEffectView.
    // The glass view uses CALayer backdrop filters internally; walk the
    // layer tree after layout to find CIGaussianBlur and lower its radius.
    DispatchQueue.main.async {
      Self.reduceBlur(in: glass)
    }
  }

  // MARK: - Legacy Visual Effect Setup (pre-26)

  private func setupLegacyVisualEffect(pillFrame: NSRect) {
    let w = pillFrame.width
    let h = pillFrame.height

    let container = NSView(frame: pillFrame)
    container.wantsLayer = true
    container.layer?.cornerRadius = Self.cornerRadius
    container.layer?.masksToBounds = true
    container.layer?.cornerCurve = .continuous

    let effect = NSVisualEffectView(frame: pillFrame)
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    self.effectView = effect
    container.addSubview(effect)

    let fill = FillView(frame: NSRect(x: 0, y: 0, width: isHorizontal ? 0 : w, height: isHorizontal ? h : 0))
    self.fillView = fill
    container.addSubview(fill)

    container.addSubview(iconView)
    container.addSubview(interactiveView)

    panel.contentView = container
  }

  // MARK: - Blur Reduction

  /// Walk a view's layer tree to find backdrop CIGaussianBlur filters and reduce their radius.
  /// NSGlassEffectView doesn't expose blur controls, so we patch the CALayer filters directly.
  private static func reduceBlur(in view: NSView) {
    guard let layer = view.layer else { return }
    Self.reduceBlurInLayer(layer)
  }

  private static func reduceBlurInLayer(_ layer: CALayer) {
    // Check backgroundFilters (backdrop filters used for behind-window blur)
    if let filters = layer.backgroundFilters as? [NSObject] {
      for filter in filters {
        // CAFilter wraps CIFilter; its name matches the CIFilter name
        if filter.responds(to: Selector(("name"))),
           let name = filter.value(forKey: "name") as? String,
           name.lowercased().contains("blur") || name.contains("gaussianBlur") {
          // Reduce blur radius — default is often ~20–40; bring it down significantly
          if filter.responds(to: Selector(("setValue:forKey:"))) {
            filter.setValue(1.5, forKey: "inputRadius")
          }
        }
      }
    }

    // Also check regular filters
    if let filters = layer.filters as? [NSObject] {
      for filter in filters {
        if filter.responds(to: Selector(("name"))),
           let name = filter.value(forKey: "name") as? String,
           name.lowercased().contains("blur") || name.contains("gaussianBlur") {
          if filter.responds(to: Selector(("setValue:forKey:"))) {
            filter.setValue(1.5, forKey: "inputRadius")
          }
        }
      }
    }

    // Recurse into sublayers
    for sublayer in layer.sublayers ?? [] {
      Self.reduceBlurInLayer(sublayer)
    }
  }

  // MARK: - Mouse Interaction

  fileprivate func handleMouseEntered() {
    isHovered = true
    // Stop any pending dismiss — keep OSD fully visible while hovered
    dismissTimer?.invalidate()
    dismissTimer = nil
    // Snap to full opacity if mid-fade
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.1
      panel.animator().alphaValue = 1
    }
  }

  fileprivate func handleMouseExited() {
    isHovered = false
    // Resume dismiss countdown if not dragging
    if !isDragging {
      dismissTimer?.invalidate()
      dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.interactiveDismissDelay, repeats: false) { [weak self] _ in
        self?.dismiss()
      }
    }
  }

  fileprivate func handleMouseEvent(_ event: NSEvent) {
    isDragging = true

    dismissTimer?.invalidate()
    dismissTimer = nil

    let localPoint = interactiveView.convert(event.locationInWindow, from: nil)
    let normalizedValue: Float

    if isHorizontal {
      normalizedValue = Float(max(0, min(1, localPoint.x / pillWidth)))
    } else {
      normalizedValue = Float(max(0, min(1, localPoint.y / pillHeight)))
    }

    let icon = Self.iconInfo(for: currentCommand, value: normalizedValue)
    update(iconName: icon.name, variableValue: icon.variableValue, value: normalizedValue)
    applyValueThrottled(normalizedValue)
  }

  fileprivate func handleMouseUp() {
    isDragging = false

    if let pending = pendingDDCValue {
      ddcThrottleTimer?.invalidate()
      ddcThrottleTimer = nil
      pendingDDCValue = nil
      applyValueToDisplay(pending)
    }

    // Only start dismiss if mouse has already left the pill
    if !isHovered {
      dismissTimer?.invalidate()
      dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.interactiveDismissDelay, repeats: false) { [weak self] _ in
        self?.dismiss()
      }
    }
  }

  // MARK: - DDC Throttling

  private func applyValueThrottled(_ value: Float) {
    let now = CACurrentMediaTime()
    let elapsed = now - lastDDCWriteTime

    if elapsed >= Self.ddcWriteInterval {
      lastDDCWriteTime = now
      pendingDDCValue = nil
      ddcThrottleTimer?.invalidate()
      ddcThrottleTimer = nil
      applyValueToDisplay(value)
    } else {
      pendingDDCValue = value
      if ddcThrottleTimer == nil {
        let remaining = Self.ddcWriteInterval - elapsed
        ddcThrottleTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
          guard let self = self, let pending = self.pendingDDCValue else { return }
          self.lastDDCWriteTime = CACurrentMediaTime()
          self.pendingDDCValue = nil
          self.ddcThrottleTimer = nil
          self.applyValueToDisplay(pending)
        }
      }
    }
  }

  private func applyValueToDisplay(_ value: Float) {
    guard let display = DisplayManager.shared.displays.first(where: { $0.identifier == displayID }) else {
      return
    }

    switch currentCommand {
    case .brightness:
      _ = display.setBrightness(value)

    case .audioSpeakerVolume:
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() {
        if !otherDisplay.readPrefAsBool(key: .enableMuteUnmute) || value != 0 {
          otherDisplay.writeDDCValues(command: .audioSpeakerVolume,
                                     value: otherDisplay.convValueToDDC(for: .audioSpeakerVolume, from: value))
        }
        otherDisplay.savePref(value, for: .audioSpeakerVolume)
      }

    case .contrast:
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() {
        otherDisplay.writeDDCValues(command: .contrast,
                                   value: otherDisplay.convValueToDDC(for: .contrast, from: value))
        otherDisplay.savePref(value, for: .contrast)
      }

    default:
      break
    }
  }

  // MARK: - Update

  private func update(iconName: String, variableValue: Double?, value: Float) {
    let v = max(0, min(1, value))

    // Use variableValue to animate wave lines while keeping the symbol frame constant.
    // speaker.wave.3.fill with variableValue 0.3 shows 1 wave highlighted, 0.6 shows 2, etc.
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: Self.iconSize * 0.75, weight: .medium)
    let baseImage: NSImage?
    if let vv = variableValue, #available(macOS 13.0, *) {
      baseImage = NSImage(systemSymbolName: iconName, variableValue: vv, accessibilityDescription: nil)
    } else {
      baseImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    }
    iconView.image = baseImage?.withSymbolConfiguration(symbolConfig)
    iconView.symbolConfiguration = symbolConfig

    // Resize fill bar
    let newFrame: NSRect
    if isHorizontal {
      let fillWidth = CGFloat(v) * pillWidth
      newFrame = NSRect(x: 0, y: 0, width: fillWidth, height: pillHeight)
    } else {
      let fillHeight = CGFloat(v) * pillHeight
      newFrame = NSRect(x: 0, y: 0, width: pillWidth, height: fillHeight)
    }

    let isVisible = panel.alphaValue > 0.01
    if isVisible && !isDragging {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = Self.fillAnimationDuration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ctx.allowsImplicitAnimation = true
        fillView?.animator().frame = newFrame
      }
    } else {
      fillView?.frame = newFrame
    }
    fillView?.needsDisplay = true
  }

  // MARK: - Show / Dismiss

  private func present(autoDismissDelay: TimeInterval = TahoeOSDWindow.dismissDelay) {
    positionOnScreen()

    dismissTimer?.invalidate()
    dismissTimer = nil

    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeInDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }

    if autoDismissDelay > 0 {
      dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
        self?.dismiss()
      }
    } else {
      dismiss()
    }
  }

  private func dismiss() {
    guard !isDragging, !isHovered else { return }
    dismissTimer?.invalidate()
    dismissTimer = nil
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = Self.fadeOutDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      self?.panel.orderOut(nil)
    })
  }

  // MARK: - Positioning

  private func positionOnScreen() {
    let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
    guard let screen = screen else { return }

    let fullFrame = screen.frame
    let visibleFrame = screen.visibleFrame
    let position = OSDPosition(rawValue: prefs.integer(forKey: PrefKey.osdPosition.rawValue)) ?? .left
    let w = pillWidth
    let h = pillHeight
    let x: CGFloat
    let y: CGFloat
    switch position {
    case .left:
      x = visibleFrame.origin.x + Self.screenEdgePadding
      y = fullFrame.origin.y + (fullFrame.height - h) / 2
    case .right:
      x = visibleFrame.origin.x + visibleFrame.width - w - Self.screenEdgePadding
      y = fullFrame.origin.y + (fullFrame.height - h) / 2
    case .top:
      x = fullFrame.origin.x + (fullFrame.width - w) / 2
      y = visibleFrame.origin.y + visibleFrame.height - h - Self.screenEdgePadding
    case .bottom:
      x = fullFrame.origin.x + (fullFrame.width - w) / 2
      y = visibleFrame.origin.y + Self.screenEdgePadding
    }

    panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
  }
}
