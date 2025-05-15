import SwiftUI
import PhotosUI

struct PhotoPicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    var selectionLimit: Int = 0 // 0 = unlimited
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.images = []
            let group = DispatchGroup()
            for result in results {
                if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                        if let image = object as? UIImage {
                            DispatchQueue.main.async {
                                self.parent.images.append(image)
                            }
                        }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                picker.dismiss(animated: true)
            }
        }
    }
} 