import AppKit
import QuickLookThumbnailing
import SceneKit
import ImageIO

class ThumbnailProvider: QLThumbnailProvider {

    // Open-source 3D box badge icon (free commercial-use vector from Alibaba Iconfont).
    private static let badgeSVG = """
    <svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" width="200" height="200">
      <path d="M528 96l374.112 208v416L528 928 153.888 720v-416z" fill="#FFFFFF"/>
      <path d="M512 208v-96h32v96h-32z m0 128v-96h32v96h-32z m0 128v-96h32v96h-32z m-257.44 217.92L168.96 725.536l-14.496-28.48L240 653.44l14.528 28.48z m114.048-58.08l-85.536 43.584-14.528-28.512 85.536-43.584 14.528 28.48z m114.048-58.112L397.12 609.28l-14.528-28.512 85.536-43.584 14.528 28.48z m333.6 87.04l85.024 44.64-14.88 28.32-84.992-44.608 14.848-28.32z m-113.344-59.456l85.024 44.608-14.88 28.352-84.992-44.608 14.848-28.352z m-113.344-59.456l85.024 44.608-14.88 28.32-84.992-44.608 14.848-28.32z" fill="#808FA1"/>
      <path d="M544 882.496l326.112-181.312V330.816L544 534.016v348.48z m-32 0v-348.48l-185.376-115.648v-37.728l41.376 25.824 5.664 3.872 0.128-0.256 154.24 96.224 316.8-197.44-316.8-176.224-112.96 62.912-23.36-23.616 1.856-1.056L528 96l374.112 208v416L528 928 153.888 720V576h32v125.184L512 882.496z m16-749.888l316.928 176.192L528 132.608z" fill="#5D6D7E"/>
      <path d="M209.376 153.408L122.72 231.648a16 16 0 1 1-21.44-23.744L225.184 96l123.904 111.904a16 16 0 0 1-21.44 23.744L241.376 153.728v316.032a16 16 0 1 1-32 0V153.408z" fill="#27A2DF"/>
    </svg>
    """

    private static let badgeImage: NSImage? = NSImage(data: Data(badgeSVG.utf8))

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maximumSize = request.maximumSize
        let scale = request.scale

        // Fast path: most slicers (Bambu Studio, OrcaSlicer, PrusaSlicer) embed a pre-rendered
        // PNG. Scale to aspect-fill the full thumbnail card with no top/bottom white bars.
        if let imageData = try? ThreeMFParser.extractEmbeddedThumbnail(fileAt: url),
           let source = CGImageSourceCreateWithData(imageData as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let reply = QLThumbnailReply(contextSize: maximumSize, drawing: { context -> Bool in
                let canvasBounds = ThumbnailProvider.bounds(of: context)
                let drawRect = ThumbnailProvider.aspectFill(imageSize: imageSize, in: canvasBounds)
                context.saveGState()
                context.clip(to: canvasBounds)
                context.draw(cgImage, in: drawRect)
                context.restoreGState()
                ThumbnailProvider.drawBadge(in: context, bounds: canvasBounds)
                return true
            })
            handler(reply, nil)
            return
        }

        do {
            let result = try ThreeMFParser.parse(fileAt: url)
            let scene = SceneBuilder.buildScene(from: result.items, showBuildPlate: false)
            // An icon sits on whatever Finder draws behind it; keep the plain white card.
            scene.background.contents = NSColor.white

            // Strip any animations (rotation) — we want a static snapshot
            scene.rootNode.enumerateChildNodes { node, _ in
                node.removeAllActions()
            }

            let pixelSize = CGSize(
                width: maximumSize.width * scale,
                height: maximumSize.height * scale
            )

            let renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = scene

            let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: .multisampling4X)

            let reply = QLThumbnailReply(contextSize: maximumSize, drawing: { context -> Bool in
                let drawRect = ThumbnailProvider.bounds(of: context)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return false
                }
                context.draw(cgImage, in: drawRect)
                ThumbnailProvider.drawBadge(in: context, bounds: drawRect)
                return true
            })

            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }

    /// The whole of a thumbnail's drawing context, in the units it draws in.
    ///
    /// Not assumed to be the requested size in points: on a Retina display the context can
    /// arrive measured in pixels, and a thumbnail drawn at the point size then fills only
    /// the bottom-left quarter of its card.
    private static func bounds(of context: CGContext) -> CGRect {
        CGRect(x: 0, y: 0, width: context.width, height: context.height)
            .applying(context.ctm.inverted())
            .standardized
    }

    private static func aspectFill(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private static func drawBadge(in context: CGContext, bounds: CGRect) {
        let side = min(bounds.width, bounds.height)
        guard side >= 24 else { return }

        let badgeBoxSize = max(14.0, round(side * 0.24))
        let margin = max(4.0, round(side * 0.055))
        let boxRect = CGRect(
            x: bounds.maxX - margin - badgeBoxSize,
            y: bounds.minY + margin,
            width: badgeBoxSize,
            height: badgeBoxSize
        )
        let cornerRadius = badgeBoxSize * 0.25
        let cardPath = CGPath(roundedRect: boxRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -max(1.0, side * 0.008)),
            blur: max(2.0, side * 0.02),
            color: NSColor(white: 0, alpha: 0.28).cgColor
        )
        context.addPath(cardPath)
        context.setFillColor(NSColor(white: 1.0, alpha: 0.94).cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(cardPath)
        context.setStrokeColor(NSColor(white: 0, alpha: 0.10).cgColor)
        context.setLineWidth(max(0.5, side * 0.004))
        context.strokePath()

        let inset = badgeBoxSize * 0.12
        let iconRect = boxRect.insetBy(dx: inset, dy: inset)
        var proposedRect = NSRect(origin: .zero, size: CGSize(width: 256, height: 256))
        if let cgBadge = badgeImage?.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            context.draw(cgBadge, in: iconRect)
        }
        context.restoreGState()
    }
}
