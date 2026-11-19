import QuickLookThumbnailing
import SceneKit
import ImageIO

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maximumSize = request.maximumSize
        let scale = request.scale

        if GCodeParser.isGCode(url) {
            do {
                handler(try gcodeThumbnail(url, maximumSize: maximumSize, scale: scale), nil)
            } catch {
                handler(nil, error)
            }
            return
        }

        // Fast path: most slicers (Bambu Studio, OrcaSlicer, PrusaSlicer) embed a pre-rendered
        // PNG. Hand it back without parsing geometry or invoking SceneKit.
        if let imageData = try? ThreeMFParser.extractEmbeddedThumbnail(fileAt: url),
           let source = CGImageSourceCreateWithData(imageData as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let reply = QLThumbnailReply(contextSize: maximumSize, drawing: { context -> Bool in
                let bounds = ThumbnailProvider.bounds(of: context)
                let drawRect = ThumbnailProvider.embeddedCoverRect(imageSize: imageSize, in: bounds)
                context.saveGState()
                context.clip(to: bounds)
                context.draw(cgImage, in: drawRect)
                context.restoreGState()
                if min(maximumSize.width, maximumSize.height) >= 64 {
                    ThumbnailProvider.draw3MFBadge(in: bounds, context: context)
                }
                return true
            })
            handler(reply, nil)
            return
        }

        do {
            let result = try ThreeMFParser.parse(fileAt: url)
            let scene = SceneBuilder.buildScene(from: result.items, showBuildPlate: false)
            handler(snapshotReply(scene, maximumSize: maximumSize, scale: scale), nil)
        } catch {
            handler(nil, error)
        }
    }

    /// A still of the scene on a white card.
    private func snapshotReply(_ scene: SCNScene, maximumSize: CGSize, scale: CGFloat) -> QLThumbnailReply {
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

        return QLThumbnailReply(contextSize: maximumSize, drawing: { context -> Bool in
            let drawRect = ThumbnailProvider.bounds(of: context)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return false
            }
            context.draw(cgImage, in: drawRect)
            return true
        })
    }

    /// The slicer's own picture of the print when it wrote one big enough to be worth
    /// showing, so the icon matches what the slicer shows and looks the same at every size.
    /// Otherwise the toolpath drawn the way the preview draws it.
    private func gcodeThumbnail(_ url: URL, maximumSize: CGSize, scale: CGFloat) throws -> QLThumbnailReply {
        if let embedded = GCodeParser.embeddedThumbnail(fileAt: url),
           max(embedded.width, embedded.height) >= Self.smallestUsableEmbeddedThumbnail,
           let source = CGImageSourceCreateWithData(embedded.data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            return QLThumbnailReply(contextSize: maximumSize, drawing: { context -> Bool in
                context.draw(cgImage, in: ThumbnailProvider.aspectFit(
                    imageSize: imageSize, in: ThumbnailProvider.bounds(of: context)))
                return true
            })
        }

        // Past the limit Finder shows the generic icon: reading the whole of a huge file
        // would cost more memory and time than a thumbnail is allowed.
        let path = try GCodeParser.parse(fileAt: url, segmentLimit: Self.thumbnailSegmentLimit)
        guard path.segmentCount > 0 else { throw GCodeParser.ParseError.nothingPrinted }
        // A smaller budget than the preview's: an icon can't show the detail, and the
        // thumbnail extension has the tighter memory limit.
        let scene = SceneBuilder.buildScene(from: path, showBuildPlate: false,
                                            tubeBudget: Self.thumbnailTubeBudget)
        return snapshotReply(scene, maximumSize: maximumSize, scale: scale)
    }

    /// PrusaSlicer's printer profiles often add a 16 px icon for the printer's own screen
    /// alongside a proper one; that size is no use as a Finder thumbnail.
    static let smallestUsableEmbeddedThumbnail = 64
    static let thumbnailTubeBudget = 100_000
    /// About 48 MB of toolpath; Finder renders many thumbnails at once.
    static let thumbnailSegmentLimit = 1_000_000
    /// Allow aspect-fill up to ~3:2 covers (33% total / ~17% per side, including standard 4:3
    /// MakerWorld thumbnails), while falling back to aspect-fit for 16:9+ covers (44%).
    static let maxCoverCropFraction: CGFloat = 0.34

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

    private static func embeddedCoverRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let croppedFraction = 1 - min(rect.width / w, rect.height / h)
        if croppedFraction <= maxCoverCropFraction {
            return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        }
        return aspectFit(imageSize: imageSize, in: rect)
    }

    private static func aspectFit(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private static func draw3MFBadge(in rect: CGRect, context: CGContext) {
        let minSide = min(rect.width, rect.height)
        let badgeSize = round(minSide * 0.16)
        guard badgeSize >= 10 else { return }

        let margin = round(minSide * 0.05)
        let badgeRect = CGRect(
            x: rect.maxX - badgeSize - margin,
            y: rect.minY + margin,
            width: badgeSize,
            height: badgeSize
        )
        let cornerRadius = badgeSize * 0.28
        let cardPath = CGPath(
            roundedRect: badgeRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -max(0.5, badgeSize * 0.04)),
            blur: max(1.5, badgeSize * 0.14),
            color: NSColor(white: 0, alpha: 0.20).cgColor
        )
        context.setFillColor(NSColor(white: 0.08, alpha: 0.56).cgColor)
        context.addPath(cardPath)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(NSColor(white: 1.0, alpha: 0.22).cgColor)
        context.setLineWidth(max(0.5, badgeSize * 0.03))
        context.addPath(cardPath)
        context.strokePath()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: badgeSize * 0.58, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "cube", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) else {
            context.restoreGState()
            return
        }
        let inset = badgeSize * 0.18
        let targetBox = badgeRect.insetBy(dx: inset, dy: inset)
        var proposedRect = targetBox
        guard let cgSymbol = symbol.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            context.restoreGState()
            return
        }
        let iconRect = aspectFit(
            imageSize: CGSize(width: cgSymbol.width, height: cgSymbol.height),
            in: targetBox
        )
        context.clip(to: iconRect, mask: cgSymbol)
        context.setFillColor(NSColor(white: 1.0, alpha: 0.92).cgColor)
        context.fill(iconRect)
        context.restoreGState()
    }
}
