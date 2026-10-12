import QuickLookThumbnailing
import SceneKit
import ImageIO

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maximumSize = request.maximumSize
        let scale = request.scale

        // Fast path: most slicers (Bambu Studio, OrcaSlicer, PrusaSlicer) embed a pre-rendered
        // PNG. Hand it back without parsing geometry or invoking SceneKit.
        if let imageData = try? ThreeMFParser.extractEmbeddedThumbnail(fileAt: url),
           let source = CGImageSourceCreateWithData(imageData as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let reply = QLThumbnailReply(contextSize: maximumSize, drawing: { context -> Bool in
                let drawRect = ThumbnailProvider.aspectFit(
                    imageSize: imageSize,
                    in: ThumbnailProvider.bounds(of: context)
                )
                context.draw(cgImage, in: drawRect)
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

    private static func aspectFit(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
