# MobileFaceNet CoreML Setup (run on Mac)

This document contains all the steps needed to convert the ONNX model to CoreML and add it to the Xcode project. Run these steps once on your Mac.

## Step 1: Install Python dependencies

```bash
pip3 install coremltools onnx numpy
```

If you don't have pip3, install Python first: `brew install python3`

## Step 2: Download the ONNX model (if not already present)

The model file `w600k_mbf.onnx` (13.6 MB) should already be in the `scripts/` folder. If it's missing (it's gitignored), download it:

```bash
cd scripts
curl -L -o w600k_mbf.onnx "https://huggingface.co/deepghs/insightface/resolve/main/buffalo_s/w600k_mbf.onnx?download=true"
```

## Step 3: Convert ONNX to CoreML

```bash
cd scripts
python3 convert_model.py
```

This produces `scripts/MobileFaceNet.mlpackage` (~14 MB).

## Step 4: Add the model to the Xcode project

1. Open `StyleMate.xcodeproj` in Xcode
2. In the Project Navigator, right-click the `StyleMate` group (the one containing `Services/`, `Views/`, etc.)
3. Select **Add Files to "StyleMate"...**
4. Navigate to `scripts/MobileFaceNet.mlpackage`
5. Check **"Copy items if needed"**
6. Check **"Add to targets: StyleMate"**
7. Click **Add**

## Step 5: Verify

1. Click `MobileFaceNet.mlpackage` in the Project Navigator
2. Xcode should show the model preview with:
   - **Input:** `input` — MultiArray (Float32) shape `[1, 3, 112, 112]`
   - **Output:** MultiArray (Float32) shape `[1, 512]` or `[1, 128]`
3. Build the project (Cmd+B) — it should compile the model into `.mlmodelc` automatically
4. `FaceMatchingService.swift` will find and load it at runtime via `Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc")`

## Troubleshooting

- **"coremltools not found"**: Make sure you're using `pip3` not `pip`, and that Python 3.8+ is installed
- **Conversion fails with unsupported ops**: Try updating coremltools: `pip3 install --upgrade coremltools`
- **Model not found at runtime**: Ensure the `.mlpackage` file is listed under the target's **"Copy Bundle Resources"** build phase in Xcode
- **Output dimension mismatch**: The w600k model outputs 512-dim embeddings. `FaceMatchingService` handles both 128 and 512 automatically via L2-normalization
