import SwiftUI
import PhotosUI

struct AddNewItemView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool
    @Binding var isPresented: Bool
    var prefilledImage: UIImage? = nil
    @State private var pickedImage: UIImage?
    @State private var detectedItems: [DetectedItem] = []
    @State private var brandInputs: [String] = []
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isAnalyzing = false
    
    struct DetectedItem: Identifiable {
        let id = UUID()
        var category: Category
        var product: String
        var colors: [String]
        var pattern: Pattern = .solid
    }
    
    func productOptions(for category: Category) -> [String] {
        productTypesByCategory[category] ?? []
    }
    
    var canSave: Bool {
        !detectedItems.isEmpty && detectedItems.indices.allSatisfy { idx in
            !detectedItems[idx].colors.isEmpty &&
            !detectedItems[idx].colors[0].trimmingCharacters(in: .whitespaces).isEmpty &&
            !detectedItems[idx].product.isEmpty
        } && pickedImage != nil
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
                
                if !detectedItems.isEmpty {
                    Section(header: Text("Detected Items")) {
                        ForEach(detectedItems.indices, id: \.self) { idx in
                            VStack(alignment: .leading, spacing: 8) {
                                Section {
                                    Picker("Category", selection: $detectedItems[idx].category) {
                                        ForEach(Category.allCases) { cat in
                                            Text(cat.rawValue).tag(cat)
                                        }
                                    }
                                    .accessibilityLabel("Category Picker")
                                    .pickerStyle(.menu)
                                }
                                Section {
                                    Picker("Product", selection: $detectedItems[idx].product) {
                                        ForEach(productOptions(for: detectedItems[idx].category), id: \.self) { prod in
                                            Text(prod).tag(prod)
                                        }
                                    }
                                    .accessibilityLabel("Product Picker")
                                    .pickerStyle(.menu)
                                }
                                Section(header: Text("Colors:").font(.subheadline)) {
                                    ForEach(Array(detectedItems[idx].colors.enumerated()), id: \.offset) { colorIdx, _ in
                                        HStack {
                                            TextField("Color", text: $detectedItems[idx].colors[colorIdx])
                                                .textContentType(.none)
                                                .autocapitalization(.none)
                                                .accessibilityLabel("Color")
                                            Spacer(minLength: 8)
                                            if detectedItems[idx].colors.count > 1 {
                                                Button(action: {
                                                    detectedItems[idx].colors.remove(at: colorIdx)
                                                }) {
                                                    Image(systemName: "minus.circle.fill")
                                                        .foregroundColor(.red)
                                                        .imageScale(.large)
                                                }
                                                .buttonStyle(BorderlessButtonStyle())
                                            }
                                        }
                                    }
                                    Button(action: {
                                        detectedItems[idx].colors.append("")
                                    }) {
                                        HStack {
                                            Image(systemName: "plus.circle.fill").foregroundColor(.green)
                                            Text("Add Color")
                                        }
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                Section {
                                    Picker("Pattern", selection: $detectedItems[idx].pattern) {
                                        ForEach(Pattern.allCases) { pattern in
                                            Text(pattern.rawValue).tag(pattern)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .accessibilityLabel("Pattern picker")
                                }
                                TextField("Brand (e.g. Nike)", text: $brandInputs[idx])
                                    .textContentType(.none)
                                    .autocapitalization(.none)
                                    .accessibilityLabel("Brand")
                            }
                            .padding(.vertical, 8)
                        }
                    }
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
                    for (idx, detected) in detectedItems.enumerated() {
                        let item = WardrobeItem(
                            category: detected.category,
                            product: detected.product,
                            colors: detected.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                            brand: brandInputs[idx],
                            pattern: detected.pattern,
                            image: img
                        )
                        wardrobeViewModel.items.append(item)
                    }
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
        .onAppear {
            if pickedImage == nil, let pre = prefilledImage {
                pickedImage = pre
                analyzeMultipleImage(pre)
            }
        }
        .onChange(of: pickedImage) { newImage in
            if let img = newImage {
                analyzeMultipleImage(img)
            }
        }
    }
    
    private func analyzeMultipleImage(_ image: UIImage) {
        isAnalyzing = true
        Task {
            let results = await ImageAnalysisService.shared.analyzeMultiple(image: image)
            detectedItems = results.compactMap { cat, prod, colors, pattern in
                if let cat = cat, let prod = prod, let pattern = pattern, !colors.isEmpty {
                    return DetectedItem(category: cat, product: prod, colors: colors, pattern: pattern)
                } else {
                    return nil
                }
            }
            brandInputs = Array(repeating: "", count: detectedItems.count)
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