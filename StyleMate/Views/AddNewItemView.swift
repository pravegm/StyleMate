import SwiftUI
import PhotosUI

struct AddNewItemView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool
    @Binding var isPresented: Bool
    var prefilledImage: UIImage? = nil
    @State private var pickedImage: UIImage?
    @State private var color: String = ""
    @State private var brand: String = ""
    @State private var selectedCategory: Category = .tops
    @State private var selectedProduct: String = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isAnalyzing = false
    
    var productOptions: [String] {
        productTypesByCategory[selectedCategory] ?? []
    }
    
    var canSave: Bool {
        !color.trimmingCharacters(in: .whitespaces).isEmpty &&
        !brand.trimmingCharacters(in: .whitespaces).isEmpty &&
        !selectedProduct.isEmpty &&
        pickedImage != nil
    }
    
    var body: some View {
        ZStack {
            Form {
                Section {
                    if let img = pickedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(12)
                    } else {
                        Image(systemName: "photo")
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .foregroundColor(.gray)
                        Text("No image selected.")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Details")) {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(Category.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .accessibilityLabel("Category Picker")
                    
                    Picker("Product", selection: $selectedProduct) {
                        ForEach(productOptions, id: \.self) { prod in
                            Text(prod).tag(prod)
                        }
                    }
                    .accessibilityLabel("Product Picker")
                    
                    TextField("Color (e.g. Black)", text: $color)
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .accessibilityLabel("Color")
                    
                    TextField("Brand (e.g. Nike)", text: $brand)
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .accessibilityLabel("Brand")
                }
            }
            .disabled(isAnalyzing)
            if isAnalyzing {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView("Analyzing image...")
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
            }
        }
        .navigationTitle("Add Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { 
                    isPresented = false 
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if !canSave {
                        errorMessage = "All fields are required."
                        showError = true
                        return
                    }
                    guard let img = pickedImage else { 
                        return 
                    }
                    let item = WardrobeItem(
                        category: selectedCategory,
                        product: selectedProduct,
                        color: color,
                        brand: brand,
                        image: img
                    )
                    wardrobeViewModel.items.append(item)
                    isPresented = false
                }
                .disabled(!canSave)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: selectedCategory) { newCat in
            selectedProduct = productTypesByCategory[newCat]?.first ?? ""
        }
        .onAppear {
            if pickedImage == nil, let pre = prefilledImage {
                pickedImage = pre
                analyzeImage(pre)
            }
            if selectedProduct.isEmpty {
                selectedProduct = productOptions.first ?? ""
            }
        }
        .onChange(of: pickedImage) { newImage in
            if let img = newImage {
                analyzeImage(img)
            }
        }
    }
    
    private func analyzeImage(_ image: UIImage) {
        isAnalyzing = true
        Task {
            let (cat, prod, col) = await ImageAnalysisService.shared.analyze(image: image)
            if let cat = cat {
                selectedCategory = cat
            }
            if let prod = prod, !prod.isEmpty {
                let validProduct = productOptions.first(where: { $0.caseInsensitiveCompare(prod) == .orderedSame })
                if let valid = validProduct {
                    selectedProduct = valid
                } else {
                    selectedProduct = productOptions.first ?? ""
                }
            } else {
                selectedProduct = productOptions.first ?? ""
            }
            let knownColors = ["black", "white", "gray", "beige", "brown", "navy", "red", "green", "blue", "yellow", "orange", "purple"]
            if let col = col, !col.isEmpty, knownColors.contains(col.lowercased()) {
                color = col.capitalized
            } else {
                color = ""
            }
            isAnalyzing = false
        }
    }
}

// UIKit camera wrapper
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    @Binding var image: UIImage?
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

#Preview {
    NavigationStack {
        AddNewItemView(
            showPhotoPicker: .constant(false),
            showCamera: .constant(false),
            isPresented: .constant(true)
        )
        .environmentObject(WardrobeViewModel())
    }
} 