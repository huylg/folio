import AppKit

/// A window that is the size the test asked for.
///
/// AppKit constrains a titled window to the screen it is on — at birth as well as on every
/// `setContentSize` — so a pane asked for at 1600x800 comes back at whatever the display can hold
/// and the test then measures a layout nobody wrote. On a CI runner, whose virtual display is
/// 1024x768 with 681pt of usable height, every spread test was quietly running one column wide and
/// every height was 653; a 15-inch laptop clamps the tall ones just the same.
///
/// These tests are about where a component lands at a given size, not about window management, so
/// the constraint is dropped and the size is taken literally.
final class TestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
