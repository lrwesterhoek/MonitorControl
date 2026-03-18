//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

/// Custom OSD window matching the macOS Tahoe (26+) pill-shaped volume/brightness indicator.
/// Supports vertical (left/right) and horizontal (top/bottom) orientations.
/// Interactive: click or drag to set brightness/volume directly.
/// Replaces the private OSDManager API which no longer renders correctly on macOS 26.
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
  /// Call this from `displayReconfigured()` in AppDelegate.
  static func cleanUpDisconnectedDisplays() {
    let connectedIDs = Set(NSScreen.screens.compactMap { $0.displayID })
    for displayID in windows.keys where !connectedIDs.contains(displayID) {
      windows[displayID]?.panel.orderOut(nil)
      windows.removeValue(forKey: displayID)
      os_log("TahoeOSD: cleaned up stale window for display %{public}@", type: .info, String(displayID))
    }
  }

  // MARK: - Fill View — uses draw(_:) for maximum reliability

  private class FillView: NSView {
    var fillColor = NSColor.white.withAlphaComponent(0.8)
    override func draw(_ dirtyRect: NSRect) {
      fillColor.setFill()
      bounds.fill()
    }
  }

  // MARK: - Interactive Hit View — handles mouse events over the entire pill

  private class InteractiveView: NSView {
    weak var osdWindow: TahoeOSDWindow?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let existing = trackingArea {
        removeTrackingArea(existing)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
        owner: self,
        userInfo: nil
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
      NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
      osdWindow?.handleMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
      osdWindow?.handleMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
      osdWindow?.handleMouseUp()
    }
  }

  // MARK: - Instance Properties

  private let panel: NSPanel
  private let containerView: NSView
  private let effectView: NSVisualEffectView
  private let fillView: FillView
  private let iconView: NSImageView
  private let interactiveView: InteractiveView
  private let displayID: CGDirectDisplayID
  private var dismissTimer: Timer?
  private var isHorizontal: Bool = false
  private var currentCommand: Command = .brightness
  private var isDragging: Bool = false
  private var lastDDCWriteTime: TimeInterval = 0
  private var pendingDDCValue: Float?
  private var ddcThrottleTimer: Timer?

  // MARK: - Public Interface

  static func showOsd(displayID: CGDirectDisplayID, command: Command, value: Float, maxValue: Float = 1) {
    let normalizedValue = maxValue > 0 ? min(max(value / maxValue, 0), 1) : 0
    let iconName = self.iconName(for: command, value: normalizedValue)
    let work = {
      let osd = self.getOrCreate(for: displayID)
      osd.currentCommand = command
      osd.applyOrientation()
      osd.update(iconName: iconName, value: normalizedValue)
      osd.present()
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async { work() } }
  }

  static func showOsdDisabled(displayID: CGDirectDisplayID, iconName: String) {
    let work = {
      let osd = self.getOrCreate(for: displayID)
      osd.applyOrientation()
      osd.update(iconName: iconName, value: 0)
      osd.present()
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async { work() } }
  }

  static func popEmpty(displayID: CGDirectDisplayID, command: Command) {
    let work = {
      let osd = self.getOrCreate(for: displayID)
      let iconName = self.iconName(for: command, value: 0)
      osd.currentCommand = command
      osd.applyOrientation()
      osd.update(iconName: iconName, value: 0)
      osd.present(autoDismissDelay: 0)
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async { work() } }
  }

  // MARK: - Icon Selection

  private static func iconName(for command: Command, value: Float) -> String {
    switch command {
    case .audioSpeakerVolume:
      if value <= 0 { return "speaker.slash.fill" }
      else if value < 0.33 { return "speaker.wave.1.fill" }
      else if value < 0.66 { return "speaker.wave.2.fill" }
      else { return "speaker.wave.3.fill" }
    case .audioMuteScreenBlank:
      return "speaker.slash.fill"
    case .contrast:
      return "circle.lefthalf.fill"
    default:
      return "sun.max.fill"
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

    containerView.frame = NSRect(x: 0, y: 0, width: w, height: h)
    effectView.frame = NSRect(x: 0, y: 0, width: w, height: h)
    interactiveView.frame = NSRect(x: 0, y: 0, width: w, height: h)

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

    // Panel: borderless, transparent, always-on-top
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: w, height: h),
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
    panel.hasShadow = true
    panel.animationBehavior = .none
    panel.alphaValue = 0
    panel.isReleasedWhenClosed = false

    // Container: clips all children to pill shape via layer mask
    containerView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = Self.cornerRadius
    containerView.layer?.masksToBounds = true
    containerView.layer?.cornerCurve = .continuous
    panel.contentView = containerView

    // Background blur: dark translucent HUD material (fills entire container)
    effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    effectView.material = .hudWindow
    effectView.blendingMode = .behindWindow
    effectView.state = .active
    effectView.appearance = NSAppearance(named: .darkAqua)
    containerView.addSubview(effectView)

    // Fill: bar that grows from bottom (vertical) or left (horizontal)
    fillView = FillView(frame: NSRect(x: 0, y: 0, width: isHorizontal ? 0 : w, height: isHorizontal ? h : 0))
    containerView.addSubview(fillView)

    // Icon: SF Symbol
    let iconFrame: NSRect
    if isHorizontal {
      iconFrame = NSRect(
        x: Self.iconEdgePadding,
        y: (h - Self.iconSize) / 2,
        width: Self.iconSize,
        height: Self.iconSize
      )
    } else {
      iconFrame = NSRect(
        x: (w - Self.iconSize) / 2,
        y: Self.iconEdgePadding,
        width: Self.iconSize,
        height: Self.iconSize
      )
    }
    iconView = NSImageView(frame: iconFrame)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = .white
    containerView.addSubview(iconView)

    // Interactive overlay: transparent view on top that captures mouse events
    interactiveView = InteractiveView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    interactiveView.osdWindow = self
    containerView.addSubview(interactiveView)
  }

  // MARK: - Mouse Interaction

  fileprivate func handleMouseEvent(_ event: NSEvent) {
    isDragging = true

    // Pause auto-dismiss while dragging
    dismissTimer?.invalidate()
    dismissTimer = nil

    // Convert click position to normalized 0-1 value
    let localPoint = interactiveView.convert(event.locationInWindow, from: nil)
    let normalizedValue: Float

    if isHorizontal {
      normalizedValue = Float(max(0, min(1, localPoint.x / pillWidth)))
    } else {
      normalizedValue = Float(max(0, min(1, localPoint.y / pillHeight)))
    }

    // Update OSD visuals immediately
    let iconName = Self.iconName(for: currentCommand, value: normalizedValue)
    update(iconName: iconName, value: normalizedValue)

    // Apply value to the display (throttled)
    applyValueThrottled(normalizedValue)
  }

  fileprivate func handleMouseUp() {
    isDragging = false

    // Flush any pending throttled value
    if let pending = pendingDDCValue {
      ddcThrottleTimer?.invalidate()
      ddcThrottleTimer = nil
      pendingDDCValue = nil
      applyValueToDisplay(pending)
    }

    // Restart dismiss timer after interaction ends
    dismissTimer?.invalidate()
    dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.interactiveDismissDelay, repeats: false) { [weak self] _ in
      self?.dismiss()
    }
  }

  // MARK: - DDC Throttling

  private func applyValueThrottled(_ value: Float) {
    let now = CACurrentMediaTime()
    let elapsed = now - lastDDCWriteTime

    if elapsed >= Self.ddcWriteInterval {
      // Enough time has passed — write immediately
      lastDDCWriteTime = now
      pendingDDCValue = nil
      ddcThrottleTimer?.invalidate()
      ddcThrottleTimer = nil
      applyValueToDisplay(value)
    } else {
      // Too soon — schedule a deferred write
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

  private func update(iconName: String, value: Float) {
    let v = max(0, min(1, value))

    // Update icon
    iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)

    // Calculate fill frame based on orientation
    let newFrame: NSRect
    if isHorizontal {
      let fillWidth = CGFloat(v) * pillWidth
      newFrame = NSRect(x: 0, y: 0, width: fillWidth, height: pillHeight)
    } else {
      let fillHeight = CGFloat(v) * pillHeight
      newFrame = NSRect(x: 0, y: 0, width: pillWidth, height: fillHeight)
    }

    // Set fill frame (animate if already visible and not dragging, otherwise snap)
    let isVisible = panel.alphaValue > 0.01
    if isVisible && !isDragging {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = Self.fillAnimationDuration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ctx.allowsImplicitAnimation = true
        fillView.animator().frame = newFrame
      }
    } else {
      fillView.frame = newFrame
    }
    fillView.needsDisplay = true

    // Icon tint: dark when over the white fill, white when over the dark background
    let iconOverFill: Bool
    if isHorizontal {
      let iconCenterX = Self.iconEdgePadding + Self.iconSize / 2
      iconOverFill = newFrame.width > iconCenterX
    } else {
      let iconCenterY = Self.iconEdgePadding + Self.iconSize / 2
      iconOverFill = newFrame.height > iconCenterY
    }
    iconView.contentTintColor = iconOverFill
      ? NSColor(white: 0.1, alpha: 0.9)
      : NSColor.white.withAlphaComponent(0.9)
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
    guard !isDragging else { return }
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
      // Center vertically on the full screen
      y = fullFrame.origin.y + (fullFrame.height - h) / 2
    case .right:
      x = visibleFrame.origin.x + visibleFrame.width - w - Self.screenEdgePadding
      // Center vertically on the full screen
      y = fullFrame.origin.y + (fullFrame.height - h) / 2
    case .top:
      // Center horizontally on the full screen (aligns under the notch)
      x = fullFrame.origin.x + (fullFrame.width - w) / 2
      // Position just below the menu bar
      y = visibleFrame.origin.y + visibleFrame.height - h - Self.screenEdgePadding
    case .bottom:
      // Center horizontally on the full screen (aligns under the notch)
      x = fullFrame.origin.x + (fullFrame.width - w) / 2
      y = visibleFrame.origin.y + Self.screenEdgePadding
    }

    panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
  }
}
