import Cocoa
import Quartz
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    private var sceneView: SCNView!

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        sceneView = SCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.width, .height]
        sceneView.backgroundColor = .white
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = true
        view.addSubview(sceneView)
        self.view = view
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let mesh = try ThreeMFParser.parse(fileAt: url)
            let scene = SceneBuilder.buildScene(from: mesh)
            sceneView.scene = scene
            handler(nil)
        } catch {
            handler(error)
        }
    }
}
