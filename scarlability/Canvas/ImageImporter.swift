#if os(iOS)
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Gets pictures from Photos, the camera, the document scanner or Files, as image data.
final class ImageImporter: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate, VNDocumentCameraViewControllerDelegate, UIDocumentPickerDelegate {
    /// Pictures to place on the page.
    var onImages: ([Data]) -> Void = { _ in }
    /// Scanned pages, to add as new pages.
    var onScans: ([Data]) -> Void = { _ in }

    func present(_ source: EditorSession.ImageSource, from presenter: UIViewController) {
        switch source {
        case .photos:
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 0
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            presenter.present(picker, animated: true)
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = self
            presenter.present(picker, animated: true)
        case .scanner:
            guard VNDocumentCameraViewController.isSupported else { return }
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = self
            presenter.present(scanner, animated: true)
        case .files:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            presenter.present(picker, animated: true)
        case .paste:
            break
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider)
        Task {
            var images: [Data] = []
            for provider in providers {
                if let data = await Self.loadImageData(provider) {
                    images.append(data)
                }
            }
            if !images.isEmpty { onImages(images) }
        }
    }

    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
            onImages([data])
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true)
        let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.8) }
        if !pages.isEmpty { onScans(pages) }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let images = urls.compactMap { try? Data(contentsOf: $0) }
        if !images.isEmpty { onImages(images) }
    }
}
#endif
