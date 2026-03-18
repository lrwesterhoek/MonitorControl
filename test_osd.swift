#!/usr/bin/env swift
import Cocoa

// Standalone test — matches the exact rendering from TahoeOSDWindow
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let w: CGFloat = 36
let h: CGFloat = 200
let cornerRadius: CGFloat = 18
let iconSize: CGFloat = 16
let iconBottomPadding: CGFloat = 10

class FillView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.white.withAlphaComponent(0.8).setFill()
    bounds.fill()
  }
}

let panel = NSPanel(
  contentRect: NSRect(x: 0, y: 0, width: w, height: h),
  styleMask: [.borderless, .nonactivatingPanel],
  backing: .buffered,
  defer: false
)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
panel.ignoresMouseEvents = true
panel.hasShadow = true
panel.isReleasedWhenClosed = false

// Container clips everything to pill shape
let containerView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
containerView.wantsLayer = true
containerView.layer?.cornerRadius = cornerRadius
containerView.layer?.masksToBounds = true
containerView.layer?.cornerCurve = .continuous
panel.contentView = containerView

// Background blur
let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
effectView.material = .hudWindow
effectView.blendingMode = .behindWindow
effectView.state = .active
effectView.appearance = NSAppearance(named: .darkAqua)
containerView.addSubview(effectView)

// Fill at 60%
let fillView = FillView(frame: NSRect(x: 0, y: 0, width: w, height: h * 0.6))
containerView.addSubview(fillView)

// Icon
let iconView = NSImageView(frame: NSRect(
  x: (w - iconSize) / 2,
  y: iconBottomPadding,
  width: iconSize,
  height: iconSize
))
iconView.imageScaling = .scaleProportionallyUpOrDown
iconView.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
iconView.contentTintColor = NSColor(white: 0.1, alpha: 0.9)
containerView.addSubview(iconView)

// Position on main screen
if let screen = NSScreen.main {
  let vis = screen.visibleFrame
  panel.setFrame(NSRect(x: vis.origin.x + 16, y: vis.origin.y + (vis.height - h) / 2, width: w, height: h), display: true)
}

panel.orderFrontRegardless()
panel.alphaValue = 1
print("OSD visible — left side of screen. Watch for 8 seconds.")

// Step through several fill levels
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
  print("→ Fill 90%, speaker icon")
  NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.3; ctx.allowsImplicitAnimation = true
    fillView.animator().frame = NSRect(x: 0, y: 0, width: w, height: h * 0.9)
  }
  fillView.needsDisplay = true
  iconView.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
  print("→ Fill 20%, speaker low icon")
  NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.3; ctx.allowsImplicitAnimation = true
    fillView.animator().frame = NSRect(x: 0, y: 0, width: w, height: h * 0.2)
  }
  fillView.needsDisplay = true
  iconView.image = NSImage(systemSymbolName: "speaker.wave.1.fill", accessibilityDescription: nil)
  iconView.contentTintColor = .white
}

DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
  print("→ Fill 0%, muted icon")
  NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.3; ctx.allowsImplicitAnimation = true
    fillView.animator().frame = NSRect(x: 0, y: 0, width: w, height: 0)
  }
  iconView.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
  print("→ Fading out")
  NSAnimationContext.runAnimationGroup({ ctx in
    ctx.duration = 0.35
    panel.animator().alphaValue = 0
  }, completionHandler: { app.terminate(nil) })
}

app.run()
