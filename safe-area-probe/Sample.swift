import AppKit

let path = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
let x = bitmap.pixelsWide / 12
for y in [4, bitmap.pixelsHigh / 2, bitmap.pixelsHigh - 5] {
    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    print(rgb.map { String(format: "%02x", $0) }.joined())
}
