import Foundation
@preconcurrency import CoreGraphics
@preconcurrency import AppKit

/// Overlay manager reference for hiding during screenshots.
/// Set by main.swift after overlay is created.
nonisolated(unsafe) weak var screenshotOverlay: OverlayManager?

/// Max bitmap width for screenshots sent to the API.
/// Anthropic recommends 1024x768 for optimal click accuracy — smaller coordinate space
/// means less prediction error. Previously 1920, changed based on CUA research.
let maxScreenshotWidth = 1024

/// Captures the macOS screen and returns JPEG data with both logical and API dimensions.
/// Hides the overlay pill during capture so it doesn't appear in screenshots.
///
/// Returns:
/// - `imageData`: JPEG bytes
/// - `logicalWidth/Height`: Real screen coordinates (for CGEvent execution)
/// - `apiWidth/Height`: Bitmap dimensions the model sees (for coordinate prediction)
func captureScreen(jpegQuality: Double = 0.75) -> (imageData: Data, logicalWidth: Int, logicalHeight: Int, apiWidth: Int, apiHeight: Int)? {
    let displayID = CGMainDisplayID()
    let logicalWidth = Int(CGDisplayPixelsWide(displayID))
    let logicalHeight = Int(CGDisplayPixelsHigh(displayID))

    guard logicalWidth > 0 && logicalHeight > 0 else { return nil }

    // Hide overlay before capture, restore after
    if let win = screenshotOverlay?.window {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { win.orderOut(nil) }
        }
        usleep(30_000) // 30ms for window server to process
    }

    // Capture ONLY the main display — .null would capture all monitors stitched together,
    // which breaks coordinate mapping on multi-monitor setups.
    let displayBounds = CGDisplayBounds(displayID)
    let cgImage = CGWindowListCreateImage(
        displayBounds,
        .optionOnScreenOnly,
        kCGNullWindowID,
        [.boundsIgnoreFraming, .bestResolution]
    )

    if let win = screenshotOverlay?.window {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { win.orderFrontRegardless() }
        }
    }

    guard let cgImage else { return nil }

    // Downscale to API resolution — always cap at maxScreenshotWidth
    let bitmapWidth: Int
    let bitmapHeight: Int
    if logicalWidth > maxScreenshotWidth {
        bitmapWidth = maxScreenshotWidth
        bitmapHeight = Int(Double(logicalHeight) * Double(maxScreenshotWidth) / Double(logicalWidth))
    } else {
        bitmapWidth = logicalWidth
        bitmapHeight = logicalHeight
    }

    // Downscale to capped resolution and encode as JPEG
    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: bitmapWidth,
        pixelsHigh: bitmapHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
    let nsImage = NSImage(cgImage: cgImage, size: rect.size)
    nsImage.draw(in: rect)

    // JPEG is much smaller than PNG — typically 5-10x for screenshots
    guard let jpegData = bitmapRep.representation(
        using: .jpeg,
        properties: [.compressionFactor: jpegQuality]
    ) else { return nil }

    return (imageData: jpegData, logicalWidth: logicalWidth, logicalHeight: logicalHeight, apiWidth: bitmapWidth, apiHeight: bitmapHeight)
}

/// Captures the screen and returns base64-encoded JPEG data with dimensions.
/// Returns API dimensions (what the model sees) as width/height, plus logical dimensions for scaling.
func screenshotBase64(jpegQuality: Double = 0.75) -> (base64: String, width: Int, height: Int, logicalWidth: Int, logicalHeight: Int)? {
    guard let (imageData, logicalWidth, logicalHeight, apiWidth, apiHeight) = captureScreen(jpegQuality: jpegQuality) else {
        return nil
    }
    return (base64: imageData.base64EncodedString(), width: apiWidth, height: apiHeight, logicalWidth: logicalWidth, logicalHeight: logicalHeight)
}
