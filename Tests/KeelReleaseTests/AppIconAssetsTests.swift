import CoreGraphics
import ImageIO
import XCTest

/// The committed icon assets that `scripts/generate-app-icon.sh` renders from `release/icon/keel-icon.svg` (DS-07 – DS-10).
final class AppIconAssetsTests: XCTestCase {
    private var icon: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("release/icon")
    }
    /// DS-10: every size exported from the source.
    private let sizes = [16, 32, 64, 128, 256, 512, 1024]
    /// `AppIcon.iconset` file names and their pixel sizes (16–512 pt @1x/@2x).
    private var iconset: [(name: String, pixels: Int)] {
        [16, 32, 128, 256, 512].flatMap { pt in [("icon_\(pt)x\(pt).png", pt), ("icon_\(pt)x\(pt)@2x.png", pt * 2)] }
    }

    func testAllSizesPresent() throws {
        for (name, pixels) in iconset { XCTAssertEqual(try image(icon.appendingPathComponent("AppIcon.iconset/\(name)")).width, pixels, name) }
        // The .icns carries every iconset image (ImageIO lists one image per size and scale).
        let icns = try XCTUnwrap(CGImageSourceCreateWithURL(icon.appendingPathComponent("AppIcon.icns") as CFURL, nil))
        let icnsSizes = Set((0..<CGImageSourceGetCount(icns)).compactMap { CGImageSourceCreateImageAtIndex(icns, $0, nil)?.width })
        XCTAssertEqual(icnsSizes, Set(sizes), "AppIcon.icns sizes")
        for look in ["dark", "tinted", "light"] {
            for px in sizes { XCTAssertEqual(try image(icon.appendingPathComponent("export/\(look)/keel-icon-\(px).png")).width, px, "\(look) \(px)") }
        }
        for look in ["default", "dark", "tinted", "light"] {
            for suffix in ["", "-small"] {
                let svg = try String(contentsOf: icon.appendingPathComponent("export/keel-icon-\(look)\(suffix).svg"), encoding: .utf8)
                XCTAssertTrue(svg.contains("viewBox=\"0 0 1024 1024\""), "\(look)\(suffix).svg")
            }
        }
        // The Icon Composer bundle: its layer exists, and the plate and mark have Dark and Tinted fills (DS-09).
        let composer = icon.appendingPathComponent("AppIcon.icon")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: composer.appendingPathComponent("icon.json"))) as? [String: Any])
        let fills = try XCTUnwrap(json["fill-specializations"] as? [[String: Any]])
        XCTAssertEqual(Set(fills.compactMap { $0["appearance"] as? String }), ["dark", "tinted"])
        let layer = try XCTUnwrap(((json["groups"] as? [[String: Any]])?.first?["layers"] as? [[String: Any]])?.first)
        let layerName = try XCTUnwrap(layer["image-name"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: composer.appendingPathComponent("Assets/\(layerName)").path))
        XCTAssertEqual(Set((layer["fill-specializations"] as? [[String: Any]] ?? []).compactMap { $0["appearance"] as? String }), ["dark", "tinted"])
    }

    /// DS-08: at 48 px and below the mark is the two-bar form. Sampled at (512, 408) on the 1024 grid: inside the full
    /// form's second bar (y 390–464) but in the small form's gap between its bars (y 390–430).
    func testSmallSizesUseSimpleForm() throws {
        var images = iconset.map { (url: icon.appendingPathComponent("AppIcon.iconset/\($0.name)"), look: "default") }
        for look in ["dark", "tinted", "light"] { images += sizes.map { (icon.appendingPathComponent("export/\(look)/keel-icon-\($0).png"), look) } }
        for (url, look) in images {
            let image = try image(url), px = image.width
            let sample = try pixel(image, x: 512, y: 408)
            // The plate beside the mark on the same row (the mark starts at x 232 in either form).
            let plate = try pixel(image, x: 150, y: 408)
            let onMark = distance(sample, markColor[look]!) < distance(sample, plate)
            XCTAssertEqual(onMark, px > 48, "\(url.lastPathComponent) (\(look), \(px) px) uses the \(px > 48 ? "full" : "small") form")
        }
    }

    /// The middle of each look's mark gradient (docs/design/icon/Icon.dc.html).
    private let markColor: [String: [Double]] = [
        "default": [254, 243, 242], "dark": [240, 90, 76], "tinted": [222, 222, 225], "light": [200, 48, 38]
    ]

    private func image(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.path)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.path)
    }

    /// The RGB of the pixel covering (x, y) on the 1024 grid.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Double] {
        let px = image.width
        var data = [UInt8](repeating: 0, count: px * px * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        // The bitmap's first row is the top of the image.
        let offset = ((y * px / 1024) * px + x * px / 1024) * 4
        return data[offset..<offset + 3].map(Double.init)
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) }
}
