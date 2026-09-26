import AppKit
import ImageIO
import Testing
@testable import PersonaStack

@MainActor
@Test func oversizedCuaScreenshotFitsRelayAndUpdatesPixelMetadata() throws {
    let width = 128
    let height = 128
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    let pixels = try #require(bitmap.bitmapData)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8(truncatingIfNeeded: x * 73 + y * 151)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: x * 193 + y * 47)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: x * 29 + y * 227)
            pixels[offset + 3] = 255
        }
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let limit = 3 * 1024
    #expect(png.base64EncodedString().utf8.count > limit)
    let result: [String: Any] = [
        "content": [["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]],
        "structuredContent": [
            "screen_width": width, "screen_height": height,
            "screenshot_width": width, "screenshot_height": height,
            "screenshot_mime_type": "image/png", "scale_factor": 1.0,
        ] as [String: Any],
    ]
    let bounded = try DesktopControlCommandExecutor.boundedCuaImageResult(result, maxEncodedImageBytes: limit)
    let content = try #require(bounded["content"] as? [[String: Any]])
    let image = try #require(content.first)
    #expect(image["mimeType"] as? String == "image/jpeg")
    let encoded = try #require(image["data"] as? String)
    #expect(encoded.utf8.count <= limit)
    let jpeg = try #require(Data(base64Encoded: encoded))
    let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let metadata = try #require(bounded["structuredContent"] as? [String: Any])
    #expect(metadata["screenshot_mime_type"] as? String == "image/jpeg")
    #expect(metadata["screenshot_width"] as? Int == decoded.width)
    #expect(metadata["screenshot_height"] as? Int == decoded.height)
    #expect(metadata["scale_factor"] as? Double == Double(decoded.width) / Double(width))
    #expect(decoded.width < width)
}

@MainActor
@Test func smallCuaScreenshotKeepsOriginalContent() throws {
    let result: [String: Any] = ["content": [["type": "image", "mimeType": "image/png", "data": "aGVsbG8="]]]
    let bounded = try DesktopControlCommandExecutor.boundedCuaImageResult(result)
    let content = try #require(bounded["content"] as? [[String: Any]])
    #expect(content.first?["data"] as? String == "aGVsbG8=")
    #expect(content.first?["mimeType"] as? String == "image/png")
}
