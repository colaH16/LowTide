// 앱 아이콘 원본(1024×1024 PNG)을 CoreGraphics로 그린다.
// 사용법: swift tools/make-icon.swift Resources/AppIcon-source.png
// 구성: 밤하늘 + 초승달(조석의 원인) + 낮아진 물결 + 원래 수위를 뜻하는 점선 만조선
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-source.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
}

/// 위쪽 경계가 사인파인 물 영역 (CG 좌표: y가 위로 증가)
func wave(base: CGFloat, amplitude: CGFloat, periods: CGFloat, phase: CGFloat, rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    let steps = 120
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = rect.minX + t * rect.width
        let y = base + amplitude * sin((t * periods + phase) * 2 * .pi)
        path.addLine(to: CGPoint(x: x, y: y))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.closeSubpath()
    return path
}

func waveLine(base: CGFloat, amplitude: CGFloat, periods: CGFloat, phase: CGFloat, rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let steps = 120
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: rect.minX + t * rect.width,
                        y: base + amplitude * sin((t * periods + phase) * 2 * .pi))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    return path
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS 아이콘 그리드: 1024 캔버스 안에 824 본체
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x0B1D3A))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// 밤하늘
linear(ctx, [rgb(0x0A1A36), rgb(0x1E4A86)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))

// 별
for (x, y, r, a) in [(250.0, 810.0, 6.0, 0.9), (340, 700, 4, 0.6), (190, 640, 3.5, 0.5),
                     (450, 840, 4.5, 0.7), (560, 760, 3, 0.45), (860, 830, 3.5, 0.5)] {
    ctx.setFillColor(rgb(0xFFFFFF, a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// 달빛 번짐
let moonCenter = CGPoint(x: 680, y: 715)
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [rgb(0xF6EED8, 0.28), rgb(0xF6EED8, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(glow, startCenter: moonCenter, startRadius: 0, endCenter: moonCenter, endRadius: 260, options: [])

// 초승달: 큰 원에서 오른쪽 위로 비킨 원을 뺀다
let moonRadius: CGFloat = 112
let moon = CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius, width: moonRadius * 2, height: moonRadius * 2)
let cut = moon.offsetBy(dx: 52, dy: 34)
ctx.saveGState()
ctx.addEllipse(in: moon)
ctx.clip()
ctx.addRect(body)
ctx.addEllipse(in: cut)
ctx.clip(using: .evenOdd)
linear(ctx, [rgb(0xFFF7E3), rgb(0xE9D9AE)], from: CGPoint(x: moon.minX, y: moon.maxY), to: CGPoint(x: moon.maxX, y: moon.minY))
ctx.restoreGState()

// 만조선: 원래 물이 있던 높이
let highWater: CGFloat = 560
ctx.saveGState()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.42))
ctx.setLineWidth(12)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [30, 30])
// 대시 주기(60)에 맞춘 길이로 양 끝이 대시로 끝나게
ctx.move(to: CGPoint(x: body.midX - 315, y: highWater))
ctx.addLine(to: CGPoint(x: body.midX + 315, y: highWater))
ctx.strokePath()
ctx.restoreGState()

// 물이 빠진 방향을 가리키는 화살표
ctx.saveGState()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let arrowX = body.midX - 150
ctx.move(to: CGPoint(x: arrowX, y: highWater - 50))
ctx.addLine(to: CGPoint(x: arrowX, y: 420))
ctx.move(to: CGPoint(x: arrowX - 34, y: 454))
ctx.addLine(to: CGPoint(x: arrowX, y: 420))
ctx.addLine(to: CGPoint(x: arrowX + 34, y: 454))
ctx.strokePath()
ctx.restoreGState()

// 뒤쪽 물결 (깊이감)
let waterRect = CGRect(x: body.minX, y: body.minY, width: body.width, height: 0)
ctx.addPath(wave(base: 350, amplitude: 20, periods: 1.6, phase: 0.35, rect: waterRect))
ctx.setFillColor(rgb(0x1C8FB8, 0.6))
ctx.fillPath()

// 앞쪽 물결
let front = wave(base: 320, amplitude: 24, periods: 1.4, phase: 0, rect: waterRect)
ctx.saveGState()
ctx.addPath(front)
ctx.clip()
linear(ctx, [rgb(0x4FD8E6), rgb(0x0A6A9A)], from: CGPoint(x: 0, y: 345), to: CGPoint(x: 0, y: body.minY))
ctx.restoreGState()

// 물마루 하이라이트
ctx.addPath(waveLine(base: 320, amplitude: 24, periods: 1.4, phase: 0, rect: waterRect))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.7))
ctx.setLineWidth(9)
ctx.strokePath()

// 위쪽 은은한 광택
linear(ctx, [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.midY))
ctx.restoreGState()

// 테두리 미세 하이라이트
ctx.addPath(shape)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
