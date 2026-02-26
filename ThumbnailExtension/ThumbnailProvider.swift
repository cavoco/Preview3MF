import QuickLookThumbnailing
import SceneKit

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maximumSize = request.maximumSize
        let scale = request.scale

        do {
            let mesh = try ThreeMFParser.parse(fileAt: url)
            let scene = SceneBuilder.buildScene(from: mesh)

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
                let drawRect = CGRect(origin: .zero, size: maximumSize)
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
}
