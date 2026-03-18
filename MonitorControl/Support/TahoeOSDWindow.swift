//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

/// Custom OSD window matching the macOS Tahoe (26+) vertical pill-shaped volume/brightness indicator.
/// Replaces the private OSDManager API which no longer renders correctly on macOS 26.
@available(macOS 11.0, *)
class TahoeOSDWindow {

  // MARK: - Layout Constants

  private static let pillWidth: CGFloat = 36
  private static let pillHeight: CGFloat = 200
  private static let cornerRadius: CGFloat = 18
  private static let iconSize: CGFloat = 16
  private static let iconBottomPadding: CGFloat = 10
  private static let screenEdgePadding: CGFloat = 16

  // MARK: - Animation Constants

  private static let fadeInDuration: TimeInterval = 0.18
  private static let fadeOutDuration: TimeInterval = 0.35
  private static let fillAnimationDuration: TimeInterval = 0.15
  private static let dismissDelay: TimeInterval = 1.5

  // MARK: - Shared State

  private static var windows: [CGDirectDisplayID: TahoeOSDWindow] = [:]

  // MARK: - Fill View — uses draw(_:) for maximum reliability

  private class FillView: NSView {
    var fillColor = NSColor.white.withAlphaComponent(0.8)
    override func draw(_ dirtyRect: NSRect) {
      fillColor.setFill()
      bounds.fill()
    }
  }

  // MARK: - Instance Properties

  private let panel: NSPanel
  private let containerView: NSView
  private let effectView: NSVisualEffectView
  private let fillView: FillView
  private let iconView: NSImageView
  private let displayID: CGDirectDisplayID
  private var dismissTimer: Timer?

  // MARK: - Public Interface

  static func showOsd(displayID: CGDirectDisplayID, command: Command, value: Float, maxValue: Float = 1) {
    let normalizedValue = maxValue > 0 ? min(max(value / maxValue, 0), 1) : 0
    let iconName = self.iconName(for: command, value: normalizedValue)
    os_log("TahoeOSD showOsd display=%{public}@ cmd=%{public}@ norm=%{public}@ icon=%{public}@",
           type: .info, String(displayID), String(reflecting: command), String(normalizedValue), iconName)
    if Thread.isMainThread {
      let osd = self.getOrCreate(for: displayID)
      osd.update(iconName: iconName, value: normalizedValue)
      osd.present()
    } else {
      DispatchQueue.main.async {
        let osd = self.getOrCreate(for: displayID)
        osd.update(iconName: iconName, value: normalizedValue)
        osd.present()
      }
    }
  }

  static func showOsdDisabled(displayID: CGDirectDisplayID, iconName: String) {
    os_log("TahoeOSD showOsdDisabled display=%{public}@", type: .info, String(displayID))
    if Thread.isMainThread {
      let osd = self.getOrCreate(for: displayID)
      osd.update(iconName: iconName, value: 0)
      osd.present()
    } else {
      DispatchQueue.main.async {
        let osd = self.getOrCreate(for: displayID)
        osd.update(iconName: iconName, value: 0)
        osd.present()
      }
    }
  }

  static func popEmpty(displayID: CGDirectDisplayID, command: Command) {
    if Thread.isMainThread {
      let osd = self.getOrCreate(for: displayID)
      let iconName = self.iconName(for: command, value: 0)
      osd.update(iconName: iconName, value: 0)
      osd.present(autoDismissDelay: 0)
    } else {
      DispatchQueue.main.async {
        let osd = self.getOrCreate(for: displayID)
        let iconName = self.iconName(for: command, value: 0)
        osd.update(iconName: iconName, value: 0)
        osd.present(autoDismissDelay: 0)
      }
    }
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

  // MARK: - Initialization

  private init(displayID: CGDirectDisplayID) {
    self.displayID = displayID

    let w = Self.pillWidth
    let h = Self.pillHeight

    // Panel: borderless, transparent, always-on-top, non-interactive
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
    panel.ignoresMouseEvents = true
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

    // Fill: white bar that grows from bottom, clipped by container's pill mask
    fillView = FillView(frame: NSRect(x: 0, y: 0, width: w, height: 0))
    containerView.addSubview(fillView)

    // Icon: SF Symbol at bottom center, drawn above fill view
    iconView = NSImageView(frame: NSRect(
      x: (w - Self.iconSize) / 2,
      y: Self.iconBottomPadding,
      width: Self.iconSize,
      height: Self.iconSize
    ))
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = .white
    containerView.addSubview(iconView)

    os_log("TahoeOSD: initialized for display %{public}@", type: .info, String(displayID))
  }

  // MARK: - Update

  private func update(iconName: String, value: Float) {
    let v = max(0, min(1, value))

    // Update icon
    iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)

    // Calculate fill height
    let fillHeight = CGFloat(v) * Self.pillHeight

    os_log("TahoeOSD update: icon=%{public}@ fillHeight=%{public}@", type: .info, iconName, String(describing: fillHeight))

    // Set fill height (animate if already visible, otherwise snap)
    let isVisible = panel.alphaValue > 0.01
    let newFrame = NSRect(x: 0, y: 0, width: Self.pillWidth, height: fillHeight)
    if isVisible {
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
    let iconCenterY = Self.iconBottomPadding + Self.iconSize / 2
    if fillHeight > iconCenterY {
      iconView.contentTintColor = NSColor(white: 0.1, alpha: 0.9)
    } else {
      iconView.contentTintColor = NSColor.white.withAlphaComponent(0.9)
    }
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

    let visibleFrame = screen.visibleFrame
    let x = visibleFrame.origin.x + Self.screenEdgePadding
    let y = visibleFrame.origin.y + (visibleFrame.height - Self.pillHeight) / 2

    panel.setFrame(
      NSRect(x: x, y: y, width: Self.pillWidth, height: Self.pillHeight),
      display: true
    )
  }
}
