# StyleMate model licensing (launch review, 2026-11-04; face and garment models replaced 2026-11-05)

StyleMate is a paid App Store app that bundles on-device ML models. On 2026-11-04 three of them,
and the training data of a fourth, were licensed for **non-commercial research only**.
**Update 2026-11-05:** the two face models (rows 1–2) are replaced by YuNet (MIT) and SFace
(Apache-2.0); SCRFD and AdaFace are no longer built or bundled (§2.6, §2.7, §8). The two garment
segmenters (FASHN parser, Fashionpedia SegFormer) are replaced by StyleMate's own **GarmentNet**
(row 3, §2.10); they are no longer built or bundled either. That was
the biggest single launch blocker. It is a legal risk, not a review risk: App Review will not
spot it, but the licence holders can file a takedown and claim damages after launch.

> **Not legal advice.** The quotes below come from the licence holders' own pages as read on
> 2026-11-04. Before launch, the founder should get counsel to sign off on the final model set,
> especially the "permissive weights trained on research-only data" question in section 3.

## 1. What ships today

| # | Model (bundle name) | Role | Size in app | Weights licence | Paid iOS app may ship it? |
|---|---|---|---|---|---|
| 1 | **YuNet 2023mar** (OpenCV Zoo), `face_detection_yunet_2023mar.onnx` (`FaceDetectYuNet.mlpackage`, fp32). *Replaced InsightFace SCRFD-10G on 2026-11-05.* | Face detection + 5 landmarks | 0.3 MB | MIT (§2.6) | **Yes**, with attribution (§3 caveat applies) |
| 2 | **SFace 2021dec** (OpenCV Zoo), `face_recognition_sface_2021dec.onnx` (`FaceEmbedSFace.mlpackage`, fp16). *Replaced AdaFace IR-101 (WebFace12M) on 2026-11-05.* | Face embedding (identity) | 18 MB | Apache-2.0 (§2.7) | **Yes**, with attribution + modification notice (§3 caveat applies) |
| 3 | **GarmentNet** (`GarmentNet.mlpackage`): StyleMate's own segmenter. Frozen **DINOv2 ViT-S/14-reg4** backbone + a head StyleMate trained from scratch on **Fashionpedia** and **COCO** people (§2.10) | Garment class per pixel, body vs scene, garment parts | 22 MB | Backbone weights Apache-2.0 (Meta). Head: StyleMate's own, trained on CC BY 4.0 annotations | **Yes**, with attribution (Apache-2.0 notice + CC BY 4.0 credits, in `ACK-14-garmentnet.md`) |
| ~~4~~ | ~~FASHN human parser (`GarmentParser`) and `sayeed99/segformer-b3-fashion` (`GarmentLabeler`)~~ | Removed 2026-11-05 (sections 2.3, 2.4) | — | NVIDIA SegFormer licence (non-commercial) | No longer bundled; CI fails if either is in `StyleMate/ML` or the Release app |
| 5 | **Marqo-FashionSigLIP** (`FashionEncoder.mlpackage` + `FashionVocabulary.json`) | Zero-shot attributes, duplicate matching | 176 MB + 1 MB | Apache-2.0 | **Yes**, with attribution |

Sizes come from CI run 41829764408 (`du -sh`); face rows from run 42008624154 (the app's `.mlmodelc`: 328 KB and 18 MB, down from 8 MB + 125 MB). GarmentNet's 22 MB from run 42027214042.

## 2. Each model, in detail

### 2.1 InsightFace SCRFD-10G (from `buffalo_l`) — no longer shipped (2026-11-05)

- **Licence text:** README of https://github.com/deepinsight/insightface, "License" section:
  - "The code of InsightFace is released under the MIT License. There is no limitation for both academic and commercial usage."
  - "The training data containing the annotation (and the models trained with these data) are available for non-commercial research purposes only."
  - "Both manual-downloading models from our github repo and auto-downloading models with our python-library follow the above license policy (which is for non-commercial research purposes only)."
  - Update dated 2025-11-24: "For open-sourced face recognition models (e.g., buffalo_l package), please contact recognition-oss-pack@insightface.ai for licensing."
- `scripts/build_face_models.sh` downloads `buffalo_l.zip` from the InsightFace v0.7 release. That is exactly the case the policy covers.
- **Commercial path exists.** https://www.insightface.ai/solutions/face-recognition-licensing offers "commercial usage rights" for `buffalo_l`, `antelopev2`, `buffalo_s` and `buffalo_m`: "Code is MIT licensed; models require separate commercial licensing."
  - Contacts: recognition-oss-pack@insightface.ai (open-source packs) and contact@insightface.ai (SDKs, including InspireFace).
  - **No prices are published.** Terms run "from single-product licenses to enterprise-wide rights" and are quoted per engagement.
- **Verdict: cannot ship without a signed licence.**
- **Opportunity:** `buffalo_l` contains both SCRFD-10G (`det_10g.onnx`) and the ArcFace R50 embedder (`w600k_r50.onnx`). One `buffalo_l` licence would therefore cover the detector and an embedder. The repo still has `scripts/convert_r50.py` for that R50 embedder (input is RGB; see CLAUDE.md).

### 2.2 AdaFace IR-101 (WebFace12M) — no longer shipped (2026-11-05)

- **Code:** MIT (https://github.com/mk-minchul/AdaFace).
  - The README gives **no licence for the pretrained checkpoints**. They are Google Drive links in a table.
- **Training data:** WebFace12M is a subset of WebFace260M/WebFace42M (Tsinghua and others). Its licence agreement is https://www.face-benchmark.org/doc/license_agreement_for_webface260m_dataset.pdf.
  - The site's TLS certificate was broken on 2026-11-04, so I could not read the PDF.
  - Every secondary source (papers, dataset indexes) describes WebFace260M as research-only, with no redistribution.
  - InsightFace applies the same "trained on research data = non-commercial" rule to its own WebFace600K models.
- **Verdict: cannot ship.** Nobody offers a commercial licence for these weights. The AdaFace authors (MSU) have no commercial programme, and the dataset licensor is a university consortium. Treat this as having no commercial path.

### 2.3 FASHN human parser (`fashn-ai/fashn-human-parser`) — replaced 2026-11-05

> **No longer shipped.** GarmentNet (§2.10) replaced it. Its converter is kept, marked
> research-only and unused, in `scripts/research/convert_segformer_wardrobe_models.py`.

- **Licence:**
  - Model card at https://huggingface.co/fashn-ai/fashn-human-parser: licence tag `nvidia-segformer`, and "This model inherits the NVIDIA Source Code License for SegFormer."
  - The GitHub repo (https://github.com/fashn-AI/fashn-human-parser) and PyPI page say the same.
  - The base model is `nvidia/mit-b4`. It was fine-tuned on "a proprietary dataset curated and annotated by FASHN AI".
- **NVIDIA licence** (https://github.com/NVlabs/SegFormer/blob/master/LICENSE), §3.3:
  - "The Work and any derivative works thereof only may be used or intended for use non-commercially."
  - "Non-commercially" means "for research or evaluation purposes only". Only "NVIDIA and its affiliates may use the Work … commercially."
  - A fine-tune counts as a derivative work.
- **Commercial terms:** FASHN publishes none. The card, repo and PyPI page name no contact for commercial use.
  - NVIDIA has a general form to "request an NVIDIA Research proprietary software license", assessed case by case: https://www.nvidia.com/en-us/research/inquiries/.
  - There are no published SegFormer terms or prices.
- **Verdict: cannot ship.** FASHN cannot relicense NVIDIA's terms. Any commercial permission would have to come from NVIDIA, and FASHN's fine-tune would also need FASHN's permission.

### 2.4 `sayeed99/segformer-b3-fashion` (Fashionpedia) — replaced 2026-11-05

> **No longer shipped.** GarmentNet (§2.10) replaced it (same research-only converter).

- **Licence:** the model card (https://huggingface.co/sayeed99/segformer-b3-fashion) has licence `other`, and "The license for this model can be found here" links to the NVlabs SegFormer LICENSE.
  - The base model is `nvidia/mit-b3`. The training dataset is `sayeed99/fashion_segmentation`, which is derived from Fashionpedia.
- **Verdict: cannot ship.** Same NVIDIA §3.3 restriction.

### 2.5 Marqo-FashionSigLIP

- **Licence:** Apache-2.0, from the model card metadata at https://huggingface.co/Marqo/marqo-fashionSigLIP.
  - It is fine-tuned from ViT-B-16-SigLIP (webli), which Google released under Apache-2.0 (big_vision / open_clip).
  - The card does not list the fine-tuning data. That residual uncertainty is small, and Apache-2.0 includes an express patent grant.
- **Verdict: can ship.** Obligations:
  - Include the Apache-2.0 licence text and any NOTICE in an in-app Acknowledgements screen (Profile → About).
  - State that the model was converted and quantized (Apache §4(b): modified files carry a notice).

### 2.6 YuNet 2023mar (ships since 2026-11-05)

- **Source:** https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet, file
  `face_detection_yunet_2023mar.onnx`, pinned to opencv_zoo commit
  `48b10fa505aeb51fbd127fc60a5c660040e823b7` (the file last changed in `f12e127`, "update yunet to v2",
  2023-06-06). SHA-256 `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`.
  The model comes from https://github.com/ShiqiYu/libfacedetection.train (BSD-3 code).
- **Licence text (read 2026-11-05):** the directory README says "All files in this directory are
  licensed under MIT License"; its LICENSE is MIT, "Copyright (c) 2020 Shiqi Yu".
- **Training data:** WIDER FACE (§3).
- **Conversion:** `scripts/convert_face_models.py` (ONNX → onnx2torch → Core ML ML program, **fp32**,
  weights unchanged). Parity, checked on every build: onnx2torch vs onnxruntime and Core ML vs
  onnxruntime on random input and on 4 fixture photos; every output cos > 0.9999 and the decoded
  faces identical (CI run 42008624154: worst cos 1.000000).
- **Obligation:** keep the copyright and MIT notice: `StyleMate/Resources/Acknowledgements/ACK-12-yunet.md`.

### 2.7 SFace 2021dec (ships since 2026-11-05)

- **Source:** https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface, file
  `face_recognition_sface_2021dec.onnx`, same pinned commit. SHA-256
  `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79`. Original code:
  https://github.com/zhongyy/SFace (the repo states no licence; the ONNX was contributed to OpenCV
  Zoo by the author's side, "ONNX file conversions … thanks to Chengrui Wang").
- **Licence text (read 2026-11-05):** "All files in this directory are licensed under Apache 2.0
  License" (README), LICENSE = Apache-2.0 full text. No NOTICE file.
- **Training data:** not stated by OpenCV. The SFace paper trains on CASIA-WebFace, VGGFace2 and
  MS-Celeb-1M (§3 caveat).
- **Conversion:** same script, **fp16** weights; Core ML vs onnxruntime cos ≥ 0.99989 on random input
  and 7 real fixture faces (CI run 42008624154).
- **Obligations (Apache-2.0 §4):** licence text + notice of modification ("converted to Core ML,
  16-bit weights"): `StyleMate/Resources/Acknowledgements/ACK-13-sface.md`.

### 2.8 Alternatives evaluated for the embedder (2026-11-05)

| Candidate | Weights licence, as read at the source | LFW accuracy in our pipeline (§8) | Verdict |
|---|---|---|---|
| **SFace** (OpenCV Zoo) | Apache-2.0, explicit for the model files | see §8 | **Chosen** |
| **dlib `dlib_face_recognition_resnet_model_v1`** | "I've released them into the public domain" / CC0-1.0 (https://github.com/davisking/dlib-models). Trained on ~3M faces, "about half … from VGG and face scrub" plus web scrapes | see §8 | Cleanest licence, but needs dlib's own 5-point landmarker + 150 px chip alignment and a C++ or ported runtime |
| **FaceNet Inception-ResNet-v1, VGGFace2** (`facenet-pytorch`, port of davidsandberg/facenet) | Repo MIT; the weights have **no stated licence**; VGGFace2's own licence could not be confirmed (sources disagree: CC BY-SA 4.0 vs non-commercial; the official page no longer shows terms) | see §8 | Not an "explicit commercial-OK" licence: not eligible |
| InsightFace `w600k_r50` (buffalo_l) | Non-commercial unless licensed (§2.1) | see §8 | Only with a signed licence (§7) |

### 2.9 Studio render model (`StudioModels.bundle`, DreamShaper 8 on SD 1.5)

- **Licence:** CreativeML OpenRAIL-M (Lykon/dreamshaper-8 model card; Stable Diffusion 1.5).
  Commercial use is allowed; the licence's use restrictions (Attachment A) must be passed on in
  the app's terms.
- **Studio coverage work (Nov 2026) added no model weights.** Shoes, hats and full-length trousers
  are drawn from procedural product templates (`StudioTemplate`: polygons filled with the item's
  own fabric, drawn in code), not from new networks. Considered and not bundled:
  - **ControlNet** (canny / lineart / softedge for SD 1.5) from the cutout's edges. Apple's Core ML
    pipeline supports it, but it needs a second ~700 MB network and a UNet re-converted with
    ControlNet inputs, and every step runs both. Worse, it would lock the render to the worn
    pose (bent knees, a pair at street angles), which is exactly what the templates remove.
  - **IP-Adapter**: needs a CLIP image tower and adapter attention layers that Apple's
    ml-stable-diffusion pipeline does not implement.
  - **LCM-LoRA** (fewer steps): changes every category's look; not evaluated for launch.
  No licence for any of these is relied on, so none is recorded as cleared.
- **Test fixtures only:** some `StyleMateTests/Fixtures/studio/` cutouts were cut offline with
  the FASHN parser (research/evaluation use, never shipped) from CC0 photos (see
  `StyleMateTests/Fixtures/CREDITS.md`).

### 2.10 GarmentNet (StyleMate's garment segmenter, ships from 2026-11-05)

One Core ML model replaces both SegFormers: `StyleMate/ML/GarmentNet.mlpackage`, input 448x672 RGB,
outputs a per-pixel class on the 384x576 analysis grid (0 scene, 1–26 Fashionpedia whole garments,
27 person-not-garment), low-res garment probabilities and hood / collar / lapel / sleeve / person maps.

| Part | What | Licence (verified at the source, 2026-11-05) |
|---|---|---|
| Backbone | **DINOv2 ViT-S/14 with 4 registers**, frozen, layers 8 and 12 (`vit_small_patch14_reg4_dinov2.lvd142m`). Weights: Meta's checkpoint (https://dl.fbaipublicfiles.com/dinov2/dinov2_vits14/dinov2_vits14_reg4_pretrain.pth) as mirrored by timm (https://huggingface.co/timm/vit_small_patch14_reg4_dinov2.lvd142m) | **Apache-2.0** for code *and* weights: "DINOv2 code and model weights are released under the Apache License 2.0" (https://github.com/facebookresearch/dinov2, README "License"). The timm card is tagged apache-2.0. Not the XRay-DINO / Cell-DINO variants, which are NC. |
| Head | ~0.9 M parameters: PCA projection of the two layers (fit on Fashionpedia training images), a token-grid context block, a 4x4 RGB patch stem and a two-step decoder (`scripts/garment/head.py`). **Trained from scratch** (no third-party segmentation checkpoint) | StyleMate's own work |
| Training data: garments | **Fashionpedia** 2020 train set (16,000 images used, plus val 1,158 for model selection): whole-garment masks of the 26 worn classes (umbrella excluded) and the hood / collar / lapel / sleeve part masks, rasterised into person crops and small-item close-ups shaped like the app's (`scripts/garment/fashionpedia.py`). Data from https://github.com/cvdfoundation/fashionpedia (S3 bucket `ifashionist-dataset`) | Annotations **CC BY 4.0** ("The annotations ... are licensed under a Creative Commons Attribution 4.0 License", https://fashionpedia.github.io/home/data_license.html). Images: "Fashionpedia does not own the copyright of the images" — Flickr / Unsplash / Pexels / ... terms of use; used only to compute training features, never redistributed (same caveat as section 3, lower risk). |
| Training data: people | **COCO 2017** train person masks (5,000 images with a large person) teach the person channel (Fashionpedia has no skin / body masks); people's clothes are ignored in the garment loss | Annotations **CC BY 4.0** ("The annotations in this dataset ... are licensed under a Creative Commons Attribution 4.0 License", https://cocodataset.org/#termsofuse). Images under the Flickr terms; training only, never redistributed. |
| Apple Vision | Only `VNDetectFaceRectanglesRequest` (`WardrobeML.faceBox`): the face box for the try-on parse and the eyewear band (below). Tried 5 Nov: `VNGeneratePersonSegmentationRequest` as an outer bound never returned inside the CI test host (a 120 s watchdog fired on every attempt), so GarmentNet's own person channel defines body. The upstream multi-person isolation (`FaceMatchingService`, person-instance mask) is unchanged | Apple platform API |
| Not used | DeepFashion2, ModaNet, LIP, ATR, CIHP, any SegFormer / Mask2Former / FASHN weights, or distillation from the old non-commercial models | — |
| Tooling | PyTorch (BSD-3), timm (Apache-2.0), pycocotools (BSD-2), OpenCV (Apache-2.0), coremltools (BSD-3). None of it ships in the app. | — |

- **Training:** `.github/workflows/garment-model.yml` on standard ubuntu runners, CPU only, no paid GPU: `pca` (fit the
  projection on 300 images) → `extract` (19 parallel chunks: frozen-backbone features stored int8, crops, labels) → `train`
  (time-budgeted cosine schedule). Settings in `scripts/garment/train_config.json`. Val mIoU (Fashionpedia val, 27 classes
  incl. "none"): **0.410 over the 27 classes (garment classes 0.388, pixel accuracy 0.927)**; per-class IoUs are in the run's `garment_head_history.json`.
- **The shipped head:** the `garment-head` artifact of run **42026153584** (https://github.com/pravegm/StyleMate/actions/runs/42026153584),
  `garment_head.pt` sha256 `1ccf3edfd20fb24793046b441c3bd849598b9208182d436dc45d8eb5df334059`, pinned in `scripts/garment/model.json`. Weights are never committed (public repo).
  **Exposure:** on a public repo any signed-in GitHub user can download a workflow artifact while it is retained, so the
  ~4 MB head (not the Core ML app model) is effectively public for 90 days. That is a business choice, not a licence
  problem: it is StyleMate's own model, its backbone is Apache-2.0 and its training annotations CC BY 4.0. To keep it
  private, set the training run's artifact retention to 1 day after CI has cached the converted model, or move the
  repo / the training workflow to a private repository.
  **Persistence (chosen: Actions cache by sha256):** the artifact expires after 90 days, so CI's `models` job keeps the
  head in the Actions cache as `garment-head-<sha256>` (restored first; the artifact is only the first source), and the
  `plan` job restores that key on every CI run so it is never evicted. Caches are branch-scoped: main's first CI run
  after the merge copies it from the artifact into main's cache. The converted app model also stays in the
  `wardrobe-models-v2-*` cache. If both caches and the artifact were ever gone, retrain with `[garment-train]`
  (deterministic in code, not bit-identical). **Keep a private copy anyway** (`gh run download 42026153584 -n garment-head`).
- **Measured (6 Nov 2026, CI run 42141881118: this branch + main's colour naming, gated on main's `labels/baseline.json`):**
  precision 0.982, recall 0.982, category 1.000, product 0.909, colour 0.891 exact / 0.927 family, fragment rate 0.036,
  15.4 s per photo on the CI simulator. Main with FASHN + SegFormer: precision 0.981, recall 0.946, category 0.962, product
  0.887, colour 0.906 / 0.943 (after studio's colour work), fragments 0.111, ~110-139 s per photo. Every metric is within the
  3-point gate; colour exact is 1.5 points lower. A further head trained on 16,000 more Fashionpedia images (run 42116538389)
  was in progress at hand-over; pin it only if the benchmark improves.
- **Conversion:** `scripts/convert_wardrobe_models.py` (via `scripts/build_wardrobe_models.sh`, CI `models` job): traced
  PyTorch → Core ML (iOS 17, fp16 compute, **int8 linear weight quantization**), plain-matmul attention (ANE-friendly), argmax and
  resize inside the model so the app reads a 221k-value class map instead of 6.9 M logits. Parity vs PyTorch fp32 on the
  fixture photos is asserted (class agreement > 0.97) in the build log. The `.mlpackage` metadata records the head sha256 and run.
- **Obligations:** Apache-2.0 §4 — ship the licence text and a modification notice for the DINOv2 weights; CC BY 4.0 — credit
  Fashionpedia and COCO, link the licence, say what was changed. Both are in
  `StyleMate/Resources/Acknowledgements/ACK-14-garmentnet.md` (the Acknowledgements screen's format; it shows up there
  once that screen is on main).
- **Body / skin / hands:** FASHN's explicit face / arm / hand classes are replaced by GarmentNet's person channel (person and
  not a garment = skin or hair; confident cells only). Measured in the CI simulator on 5 Nov: Vision's person-instance mask and
  a standalone person segmentation work, hand pose returns no hands, body pose fails, and person segmentation inside the
  extraction tests never returned, so no Vision mask request is used by the garment pipeline itself.
- **Face rectangles:** Apple Vision's `VNDetectFaceRectanglesRequest` (part of iOS, no extra licence) gives one face box
  per image (`WardrobeML.faceBox`). Try-on's parse uses it to label the neck under the face as skin rather than the old
  top, and to split the body class into face and hair. The wardrobe cutout keeps eyewear to the box's eye band, so hair
  at the temples is not cut out with sunglasses. Without a box, both fall back to the grid alone.

## 3. A caveat that applies to every "permissive" face model

Almost every public face detector and recogniser was trained on research-only data:

- WIDER FACE for detectors. Hugging Face lists it as `cc-by-nc-nd-4.0`.
- MS-Celeb, CASIA-WebFace, VGGFace2 or WebFace for recognisers.

Some releasers still put the **weights** under MIT or Apache: OpenCV for YuNet and SFace, Davis King for dlib (public domain). Whether a dataset's non-commercial term reaches weights that someone else released permissively has **not been settled in court**. Industry practice treats those weights as usable. The risk is much lower than shipping a model whose own licence says "non-commercial", but it is not zero. Counsel should sign off.

No commercially usable, large-scale face-ID training set exists:

- The synthetic sets are research-only too. DigiFace-1M is "for non-commercial research" (https://microsoft.github.io/DigiFace1M). DCFace and IDiff-Face are built on FFHQ/CASIA.
- **Retraining a face recogniser on clean data is therefore not a realistic launch option.**

## 4. Commercially safe alternatives

### 4.1 Face detection with 5-point landmarks (replaces SCRFD)

**Done 2026-11-05: YuNet ships (§2.6).**

| Option | Licence (URL) | Landmarks | Notes |
|---|---|---|---|
| **YuNet** (OpenCV Zoo, `face_detection_yunet_2023mar.onnx`) | MIT: "All files in this directory are licensed under MIT License" (https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet). Training repo is BSD-3 (https://github.com/ShiqiYu/libfacedetection.train) | 5 points: right eye, left eye, nose tip, right and left mouth corner. Same set as ArcFace; OpenCV's `FaceRecognizerSF.alignCrop` uses them directly | About 0.3 MB, tiny and fast. Trained on WIDER FACE (see §3). Converts to Core ML through ONNX → PyTorch (`onnx2torch`, already used for SCRFD). **Best drop-in.** |
| InsightFace `buffalo_l` (SCRFD-10G) **with a commercial licence** | Contract with InsightFace (§2.1) | Same as today | Zero engineering if the licence comes through. Price and lead time unknown. |
| MediaPipe Face Detector (BlazeFace) + Face Landmarker | Apache-2.0 (https://github.com/google-ai-edge/mediapipe; model cards linked from https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker) | BlazeFace gives 6 keypoints (eyes, nose tip, mouth centre, ear tragions) but **no mouth corners**. Face Landmarker gives 478 points, so mouth corners are available | Two models per face. BlazeFace short-range is tuned for selfie distance and weak on small faces in group or street photos. iOS SDK via CocoaPods `MediaPipeTasksVision`. |
| dlib MMOD detector + `shape_predictor_5_face_landmarks` | Public domain / CC0: "anyone can do whatever they want with these model files" (https://github.com/davisking/dlib-models) | dlib's own 5 points (four eye corners + nose base), **not** ArcFace's 5 | Cleanest licence statement of all, but needs dlib C++ on iOS or a port. Older and slower. Avoid the 68-point model, which is non-commercial (iBUG 300-W). |
| Apple Vision `VNDetectFaceRectanglesRequest` | Part of iOS | Not usable as-is | CLAUDE.md records that Vision landmarks collapsed same-person similarity (0.988 → about 0.2). Usable only as a box proposer in front of YuNet landmarks. |

### 4.2 Face recognition (replaces AdaFace)

**Done 2026-11-05: SFace ships (§2.7); measured against dlib, FaceNet and the old stack in §8.**

| Option | Licence (URL) | Quality | Notes |
|---|---|---|---|
| **InsightFace `w600k_r50` from `buffalo_l` with a commercial licence** | Contract (§2.1) | Close to AdaFace on clean photos (ArcFace R50 on WebFace600K) | `scripts/convert_r50.py` already exists. Input is RGB, so undo the BGR plane swap in `createInputMultiArray` and bump `FaceMatchingService.modelVersion`. **Best quality per dollar if the price is acceptable.** |
| InsightFace InspireFace SDK / closed models | Contract (contact@insightface.ai) | Vendor claims higher than open packs | A full SDK, so it would replace more of the pipeline. Enterprise-oriented. |
| **SFace** (OpenCV Zoo, `face_recognition_sface_2021dec.onnx`) | Apache-2.0: "All files in this directory are licensed under Apache 2.0 License" (https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) | LFW 99.40% (OpenCV's table). MobileFaceNet-sized, so expect a **clearly lower** hit rate than IR-101 on profile, low-light, sunglasses and small faces | 128-d output, 112×112 aligned, same ArcFace alignment template as now. OpenCV does not state the training data (§3). **Best free option.** |
| dlib `dlib_face_recognition_resnet_model_v1` | Public domain / CC0 (https://github.com/davisking/dlib-models) | LFW 99.38%. Trained on about 3M faces (FaceScrub, VGG, scraped) | Has its own alignment (dlib 5-point), so it must be paired with dlib's landmarker. Port effort is higher than SFace. |
| Commercial on-device SDKs (Luxand FaceSDK, Regula, Neurotechnology VeriLook, Paravision and others) | Contract. Luxand is quote-only (sales@luxand.com; https://www.luxand.com/facesdk/) | Varies | Adds a closed binary and a per-app or per-install fee. Check that they process fully on-device (no server or telemetry), or the privacy story breaks. |

### 4.3 Garment segmentation (replaces FASHN + the Fashionpedia SegFormer)

> **Done 2026-11-05: option 2 shipped as GarmentNet (§2.10)** — DINOv2 ViT-S/14 frozen + a head trained on Fashionpedia,
> on CPU CI runners instead of a rented GPU (no cost), with COCO person masks standing in for FASHN's body classes. The text
> below is the original analysis.

**No commercial licence route is known for either SegFormer.** Options:

1. **Ask NVIDIA** through the research-licence request form (https://www.nvidia.com/en-us/research/inquiries/) for a commercial licence to MiT-B3/B4 derivatives, and **ask FASHN** (https://fashn.ai) about their fine-tune. A long shot, and it should not be on the critical path.
2. **Retrain one model on Fashionpedia** with a permissively licensed backbone (recommended):
   - **Data:**
     - Fashionpedia annotations are CC BY 4.0 ("licensed under a Creative Commons Attribution 4.0 License", https://fashionpedia.github.io/home/data_license.html). Attribution goes in Acknowledgements.
     - Images: "The Fashionpedia does not own the copyright of the images. Use of the images must abide by the Terms of use of" Flickr, Unsplash, Burst, Freestocks, Kaboompics and Pexels. Those are mostly free-licence photo sites.
     - Training a model on them without redistributing the images is common practice, but has the same unsettled-law caveat as §3, at a lower risk level.
     - Size: 48,825 images, 27 main garment classes plus 19 parts.
   - **Backbone choices, all with commercial-OK weights. Start only from backbone weights, never from someone else's segmentation checkpoint:**
     - **DINOv2 ViT-S/14 or ViT-B/14** with a linear or DPT head. Apache-2.0 for code and weights: "DINOv2 code and model weights are released under the Apache License 2.0" (https://github.com/facebookresearch/dinov2). Strong dense features and fast convergence. ViT-S is about 22M parameters, roughly 22 MB at int8. Avoid the XRay-DINO and Cell-DINO variants, which are NC.
     - **ConvNeXt-T/S + UPerNet.** MIT ImageNet weights (https://github.com/facebookresearch/ConvNeXt). UPerNet head from mmsegmentation (Apache-2.0). Good edges and Core ML-friendly (pure conv).
     - **torchvision DeepLabV3+ on MobileNetV3 or ResNet-50 ImageNet weights.** BSD-3 (https://github.com/pytorch/vision). Smallest and fastest, roughest edges.
     - The SegFormer *architecture* (Hugging Face `transformers`, Apache-2.0) is fine when **trained from scratch or from a non-NVIDIA backbone**. LibreYOLO's card makes the same point: "Models trained from scratch … are also unrestricted" (https://huggingface.co/LibreYOLO/LibreSegformerb0-sem). Its own SegFormer weights are still the NVIDIA NC ones.
     - **Avoid** off-the-shelf segmentation checkpoints with unclear licences. For example, `facebook/mask2former-*` on Hugging Face is tagged `other`.
   - **What FASHN did that Fashionpedia does not:** explicit skin, arms and hands classes.
     - Replace them with what the app already has: Apple Vision's person-instance mask (`VNGeneratePersonInstanceMaskRequest`) and foreground mask.
     - Body = person mask − garment mask. Hands can be cut out with `VNDetectHumanHandPoseRequest`.
     - This also **merges two models (108 MB) into one** of about 25–90 MB.
   - **Effort:**
     - About 1 engineer-week: convert the polygons to 27-class masks, train, run Core ML conversion with the existing `parity()` checks, adapt `GarmentSegmenter` and `WardrobeExtractor` to one map plus the Vision body mask, and re-run the 10-photo benchmark and the CI cutout report.
     - Plus about 12–24 GPU-hours on one A100/H100 for 40–80k iterations at 512 px, around **$50–300** of cloud GPU.
     - Risk: edge quality may fall below today's FASHN + Fashionpedia fusion. The CI `ci-report` cutouts are the acceptance gate.
3. **Promptable segmenter + labeler.** MobileSAM or SAM 2.1 (Apache-2.0, https://github.com/facebookresearch/sam2) with box prompts, plus FashionSigLIP to label crops. More moving parts and slower per item. A fallback if option 2's edges disappoint.

Do **not** train on DeepFashion2, ModaNet, LIP/ATR or CIHP. Their licences are non-commercial or research-only.

## 5. Recommended launch path (ranked)

**Status 2026-11-05:** the face half of path 1 is done: YuNet + SFace are the default and the
`buffalo_l` swap is a documented manual change (§7). The InsightFace email is drafted (§9), not sent.

The garment retrain (§4.3 option 2) was on the critical path whatever happens with face models. **It is done (GarmentNet, §2.10, 2026-11-05).**

| Rank | Path | Legal status | Time to launch-ready | Quality risk | Cost |
|---|---|---|---|---|---|
| **1 (recommended)** | **Today:** email InsightFace (recognition-oss-pack@insightface.ai, cc contact@insightface.ai) for a single-app, on-device iOS licence to `buffalo_l` (SCRFD-10G + w600k_r50). **Same day:** start the Fashionpedia retrain on DINOv2-S or ConvNeXt-T, and build the YuNet + SFace face pipeline behind a flag. Ship with `buffalo_l` if the signed licence and price land before the garment model is ready (about 1–2 weeks); otherwise ship YuNet + SFace and move to `buffalo_l` in 1.1. Keep FashionSigLIP. | Clean once signed. Without the signature, the YuNet/SFace fallback carries only the §3 caveat | 1–2 weeks | Face: low with `buffalo_l`, medium with SFace. Garments: medium | InsightFace quote (unknown) + about $50–300 GPU |
| 2 | Fully free stack: YuNet + SFace + retrained Fashionpedia segmenter + FashionSigLIP | §3 caveat only. No contracts | About 1.5 weeks | **Medium–high on the USP** (CLAUDE.md: face matching "must be error-less"). Tune thresholds and the margin again on the CI fixtures and the founder's own library | About $50–300 |
| 3 | dlib (CC0) face stack instead of YuNet + SFace | Cleanest licence wording | 2–3 weeks (C++ or port) | Similar to SFace, older | Engineering time |
| 4 | Commercial on-device face SDK (Luxand or similar) | Clean by contract | 2–4 weeks (procurement + integration) | Vendor-dependent | Per-app or per-install fees |
| ✗ | Ship the current models and "fix later" | **Licence breach** (InsightFace, NVIDIA ×2, WebFace). Exposure to takedown/DMCA notices and damages claims, and an App Store listing that has to be pulled | — | — | — |

**Honest uncertainty:**

- InsightFace's price and turnaround are unknown; nothing is published.
- How much worse SFace is than AdaFace on real libraries has not been measured. That must be benchmarked before choosing path 2.
- The retrained garment model's edge quality cannot be known before training.
- The §3 question (permissive weights trained on non-commercial data) is a judgement call for counsel, not a settled answer.

## 6. Housekeeping required for any path

- **Acknowledgements screen** in the app (Profile → About → Acknowledgements) with:
  - Licence texts for FashionSigLIP and SigLIP (Apache-2.0), Fashionpedia (CC BY 4.0 attribution), YuNet (MIT) / SFace (Apache-2.0) if used, DINOv2 / ConvNeXt (Apache / MIT) if used.
  - Garment model (DINOv2 Apache-2.0 + Fashionpedia / COCO CC BY 4.0): `StyleMate/Resources/Acknowledgements/ACK-14-garmentnet.md`.
  - GoogleSignIn-iOS and its dependencies AppAuth, GTMAppAuth and GTMSessionFetcher (Apache-2.0), if Google Sign-In stays.
  - **Done (5 Nov 2026, `feat/diagnostics`)**: the screen exists and lists every `ACK-<order>-<slug>.md` in
    `StyleMate/Resources/Acknowledgements/` (format in `ACKNOWLEDGEMENTS-HOWTO.txt` there). Seeded with, each
    verified at its source on 5 Nov: Marqo-FashionSigLIP + SigLIP ViT-B-16 (Apache-2.0 full text from
    apache.org; model cards at huggingface.co/Marqo/marqo-fashionSigLIP and timm/ViT-B-16-SigLIP say
    apache-2.0; notice: converted to Core ML, fp16), Stable Diffusion 1.5 / DreamShaper 8 (CreativeML Open
    RAIL-M full text incl. Attachment A from github.com/CompVis/stable-diffusion; Lykon/dreamshaper-8 card says
    creativeml-openrail-m; notice: Core ML, 6-bit palettized UNet + text encoder, no safety checker), Apple
    ml-stable-diffusion (MIT, LICENSE.md at the pinned commit), MET Norway (NLOD 2.0 + CC BY 4.0, "Based on
    data from MET Norway") and Open-Meteo (CC BY 4.0). There are no Swift packages (the project has no package
    references). **Whoever adds or swaps a model adds / deletes its file there.** YuNet (`ACK-12-yunet.md`, MIT) and SFace (`ACK-13-sface.md`, Apache-2.0 + modification notice) were added on 5 Nov with the face swap; SCRFD / AdaFace no longer ship. Still to add if they keep
    shipping: FASHN parser / Fashionpedia labeler texts (NVIDIA SegFormer licence §3.1 asks
    for a copy of the licence with any redistribution; Fashionpedia annotations are CC BY 4.0).
  - Open-Meteo's licence also asks for a link "next to any location Open-Meteo data are displayed"; the weather
    card shows none yet.
- Record each shipped model's source URL, licence, commit or hash and conversion script in this file. Bump `FaceMatchingService.modelVersion` on any face-model swap (CLAUDE.md).
- Keep the weights out of public artifacts. The repo is **public**; CI keeps the models only in the Actions cache, which is correct.

## 7. Plugging in InsightFace `buffalo_l` (only with a signed licence)

The code path is kept ready: `FaceModelSet.insightFaceBuffaloL`, `FaceModelProfile.insightFaceBuffaloL`,
`SCRFDDetector` (SCRFD-10G decoder) and the converters in `scripts/face_legacy/`. Nothing of it is
built or bundled today. If the founder signs an InsightFace licence that covers `det_10g.onnx` and
`w600k_r50.onnx` in a paid iOS app (on-device, bundled in the binary, converted to Core ML fp16):

1. **Profile.** `StyleMate/Services/FaceModelProfile.swift`: `static let active: FaceModelProfile = .insightFaceBuffaloL`.
   Check its bars against §8 (they are the equal-FAR calibration of the R50 on the same LFW protocol)
   and against the CI `faces.txt` benchmark of the first green run.
2. **Build (manual, on purpose).** No build script can fetch InsightFace weights. With the licence
   signed, add a step to `scripts/build_face_models.sh` (and bump its `face-models` cache key in
   `ci.yml`, `duo.yml`, `testflight.yml`) that downloads `buffalo_l.zip` from the source named in
   the contract, checks its SHA-256, and runs
   `python face_legacy/convert_scrfd.py <det_10g.onnx> "$OUT/FaceDetectSCRFD.mlpackage"` and
   `python face_legacy/convert_r50.py <w600k_r50.onnx> "$OUT/FaceEmbedArcFaceR50.mlpackage"`
   (both parity-check against onnxruntime), and drop the YuNet / SFace steps. Add the two
   converters to the cache key's `hashFiles(...)`. `StyleMate/FaceModels/` is a synchronized
   folder, so the Xcode project needs no edit.
3. **Licence gate.** `scripts/check_face_models.sh`: expect `FaceDetectSCRFD.mlmodelc` and
   `FaceEmbedArcFaceR50.mlmodelc`, and drop those two names from the forbidden list.
4. **Acknowledgements.** Replace `StyleMate/Resources/Acknowledgements/ACK-12-yunet.md` /
   `ACK-13-sface.md` with whatever attribution the InsightFace contract requires.
5. **Users.** `modelVersion` changes (`scrfd10g_w600k_r50_flip`), so every stored gallery is discarded
   and rebuilt from the selfie frames on first launch. Faces confirmed in "Find yourself" / "Is this
   you?" are lost (the app keeps their embeddings, not their photos): prompt the user to run
   **Improve Recognition** again, or swap before launch.
6. **Docs.** This file (§1 table, licences, hashes), README "How it works", CLAUDE.md face notes.

Swift needs no other change: the R50 input (RGB, (px−127.5)/127.5, 512-d) is described by the
profile, and `FaceDetector.shared` switches to `SCRFDDetector`.

## 8. Measurements: old stack (SCRFD-10G + AdaFace IR-101) vs new (YuNet + SFace), 2026-11-05

**Evaluation only.** LFW (Labeled Faces in the Wild, UMass; research benchmark, downloaded via the
scikit-learn figshare mirror) was used to *measure*; nothing derived from it ships. The lab mirrors
the Swift pipeline (letterboxed 640 detector input, 5-point similarity warp to the ArcFace template,
cosine of L2-normalized embeddings). It is not in the repo (the scripts live in the session's
scratchpad); the CI fixture benchmark below is the in-repo, repeatable part. The old stack was run
with the CVLFace safetensors copy of the same AdaFace IR-101 WebFace12M weights (Google Drive is
blocked here); its RGB order beat BGR on the fixtures, matching the app's BGR-checkpoint setup.
The lab CPU was shared and slow, so the old stack (IR-101 is ~24 GFLOPs per face) was measured on
a 2,440-photo subset; SFace was also measured on all 13,233 photos.

Protocols. *pair*: every same-person pair vs every different-person pair. *g3*: the app's setup:
each identity's first 3 photos are the gallery ("3-frame selfie"), the next photo the probe, every
other identity's photos the impostors; *single* = best gallery match (the old app), *top-2* = mean
of the two best (the new consensus). A photo the detector misses counts as a rejected genuine. FAR
is per probe-vs-gallery comparison. At FAR ≤ 1e-6 the LFW numbers are dominated by LFW's own label
errors (a handful of "impostor" photos that are the same person), so they flatten out there.

### 8.1 Identity accuracy on LFW (2,440-photo subset, 610 identities)

| | Old: SCRFD + AdaFace IR-101 | New: YuNet + SFace (flip-averaged) |
|---|---|---|
| Photos with no face found | 0.04% | 0.00% |
| Same-person similarity: median / 5th percentile | 0.706 / 0.536 | 0.698 / 0.513 |
| Different-person similarity: mean / 99.9th percentile | 0.003 / 0.193 | 0.102 / 0.371 |
| **pair** TAR at FAR 1e-4 / 1e-5 | 99.81% / 99.81% | 98.88% / 97.02% |
| **3-photo gallery** TAR at FAR 1e-4 / 1e-5 (old: single best; new: top-2 consensus) | 99.67% / 99.67% | 99.34% / 98.36% |
| **At the app's auto-add bar** (old 0.55 single; new 0.58 top-2) | TAR 97.87%, FAR 6.7e-7 | TAR 94.26%, FAR 6.7e-7 |
| **At the app's review bar** (old 0.30; new 0.45, single best) | TAR 99.67%, FAR 3.1e-5 | TAR 99.34%, FAR 7.4e-5 |

(FAR 6.7e-7 is one LFW "impostor" out of 1.49M, a label error that every model scores as the
same person.) The full 13,233-photo LFW with SFace agrees: official 6,000-pair accuracy 99.48%
(99.43% without flip; OpenCV's table: 99.40%), pair TAR 98.34% / 94.93% at FAR 1e-4 / 1e-5.

**Reading it:** on clean faces SFace is close, but its stranger scores are much higher (mean 0.10
vs 0.003), so for the same false-accept rate it must reject more of the user's own photos: about
3x as many genuine rejections at FAR 1e-5 (pair: 2.98% vs 0.19%). The app absorbs most of that in
its review tier: at the new bars ~94% of clean photos of you auto-add (old ~98%) and ~99.3% reach
at least "Is this you?" (old ~99.7%), while strangers are kept at the old auto-add rate. Review
will see about 2.4x more strangers than before (7.4e-5 vs 3.1e-5 per face per gallery check:
roughly 1 extra stranger per 25,000 library faces).

### 8.2 Hard cases (150 probes per case, gallery = 3 clean photos)

The same 150 LFW identities, the probe photo degraded; each model at its own FAR-matched bars
(from its clean gallery protocol). "Missed" = no face found. TAR at FAR 1e-4 / 1e-5.

| Case | Old: SCRFD + AdaFace | New: YuNet (+ tiles) + SFace |
|---|---|---|
| Distant face, ~24 px in a 640 px "Find yourself" thumbnail | missed 0.0%, TAR 99.3% / 99.3% | missed 2.7%, TAR 82.0% / 64.7% |
| Same distant face in the **960 px** thumbnail the app now uses (~36 px) | — | missed 1.3%, TAR 88.0% / 80.0% |
| Distant face, ~48 px in a 1600 px scan photo (detector sees ~19 px; new stack tiles) | missed 2.0%, TAR 97.3% / 97.3% | missed 0.7%, TAR 95.3% / 90.0% |
| Sunglasses (dark lenses painted over the eyes from the landmarks; synthetic) | missed 0.7%, TAR 98.7% / 98.7% | missed 0.0%, TAR 89.3% / 68.0% |
| Frame-filling selfie face (needs the pad retry) | missed 0.7%, TAR 98.7% / 98.7% | missed 0.0%, TAR 94.7% / 90.0% |

Old-stack probes were flip-averaged here (its gallery was not), a small advantage to it. LFW has
too few strong profiles for a profile row; on the fixtures the cap + sunglasses + profile face is
the weakest same-person score for both stacks (§8.5). **This is where the free stack is clearly
worse:** tiny, occluded and turned faces lose 10–35 points of TAR at strict FAR (the 960 px thumbnail wins back about half of it for distant faces). In the app those
photos mostly drop from auto-add to "Is this you?" or, below 0.45, are skipped; nothing about them
raises the risk of adding a stranger.

### 8.3 What the test-time tricks bought (SFace, LFW)

| Trick | Measured effect | Shipped |
|---|---|---|
| Flip-averaged embedding (face + mirror) | pair TAR at FAR 1e-5 94.30% → 94.93% (full LFW); 6,000-pair accuracy 99.43% → 99.48%; also makes mirrored selfies match | Yes |
| 3-frame selfie gallery instead of one photo | TAR at FAR 1e-5: pair 97.0% → 3-photo gallery 98.4% (subset) | Yes (already in the app) |
| **Top-2 consensus** instead of max over the gallery | with a **10-photo** gallery (after "Find yourself"), TAR at FAR 1e-5: max 74.4% → top-2 99.5% (the max admits more strangers the bigger the gallery gets) | Yes, for auto-add / multi-person / learning; review keeps the single best |
| Small-face tile pass (2x2 overlapping 60% tiles at full input, for photos ≥ 1100 px) | 48 px faces in 1600 px photos: misses 5.6% → 0.3%, TAR at FAR 1e-5 79.0% → 93.8% | Yes |
| "Find yourself" thumbnail 640 → 960 px | ~24 px faces (now ~36 px): misses 2.7% → 1.3%, TAR at FAR 1e-4 / 1e-5 82.0 / 64.7% → 88.0 / 80.0%. Lab CPU time per photo unchanged (one 640 detector pass either way: 82 → 76 ms); PhotoKit cache window 40 → 18 photos so cached bytes stay ~66 MB | Yes |
| Quality-weighted crops / templates | Not adopted: quality is already a gate (detector score, size, yaw) and the gallery picks are a diverse spread; no measured gain to justify a weighting | No |
| Confirmed library faces as extra templates ("Is this you?" picks) | Already the gallery design; the consensus score is what makes a large gallery safe (row above) | Yes |

### 8.4 Alternative recognisers (same YuNet detections, same subset)

| Recogniser | Licence of the weights | g3 TAR at FAR 1e-4 / 1e-5 | pair TAR at FAR 1e-4 / 1e-5 |
|---|---|---|---|
| **SFace** (flip) | Apache-2.0 | **99.34% / 98.36%** | **98.88% / 97.02%** |
| dlib ResNet v1 (flip; dlib's own 5-point landmarks inside YuNet's box, 150 px chip) | Public domain / CC0 | 93.11% / 73.11% | 82.24% / 58.09% |
| FaceNet Inception-ResNet-v1 VGGFace2 (160 px, our 5-point warp, not its native MTCNN box crop, so understated) | no stated licence on the weights (not eligible) | 54.59% / 32.62% | 38.93% / 21.69% |
| *InsightFace w600k_r50 (buffalo_l, SCRFD detections), for the licensed path* | non-commercial unless licensed | 99.67% / 99.67% | 99.81% / 99.81% |

dlib is far behind here (it was trained for its own detector's boxes; even so the gap is large),
so SFace is the pick by measured accuracy, not only by convenience.

### 8.5 CI fixture benchmark (the repo's 13 CC0 photos, `FaceMatchingTests.fixtureFaceBenchmark`)

Each fixture face vs itself under 5 photo transforms (re-frame, half size, mirror, 40% darker,
JPEG q30) = same-person; every pair of faces from different photos = different-person. The six
`street_*` photos are one Wikimedia series that probably shows the same woman, so their cross
pairs are reported apart, not as impostors.

| | Old (lab, Python) | New (lab, Python) | New (CI, Swift/Core ML, run 42062320357) |
|---|---|---|---|
| Faces found | 11 | 12 | 12 |
| Same-person: min / 10th pct / median | 0.846 / 0.887 / 0.954 | 0.484 / 0.790 / 0.938 | 0.562 / 0.759 / 0.921 |
| Different-person: max / mean | 0.125 / 0.014 | 0.283 / 0.088 | 0.305 / 0.102 |
| At the app's bars | auto-add TAR 100%, FAR 0% | — | auto-add (0.58) TAR 98.2%, FAR 0%; review (0.45) TAR 100%, FAR 0% |

The Swift numbers track the Python twin, which cross-checks the Swift port (letterbox, BGR order,
alignment, flip averaging). The cap + sunglasses + profile face (`street_coat_cap`) is the weak
spot: its re-framed copy scored 0.52 before the tile pass and 0.94 with it (better landmarks from
2.5x the pixels). Both CI numbers are in `faces.txt` of the `ci-report` artifact.

### 8.6 Worse / better, in one place

- **Worse:** strangers score higher (mean 0.10 vs 0.003); at equal false accepts ~3x more of your
  own photos fall short of auto-add (most go to "Is this you?"); faces in sunglasses / strong
  profile / very small lose more similarity than with AdaFace (§8.2); review sees ~2.4x more
  strangers.
- **Better:** commercially licensed; 18.3 MB of face weights instead of 133 MB (app ~115 MB
  smaller, less memory; in the lab SFace ran ~60x faster per face on CPU than IR-101); no missed LFW faces; small
  faces in big photos found and matched far better (tile pass); a large confirmed gallery can no
  longer let a stranger in through one odd entry (top-2 consensus, which also protects a future
  buffalo_l swap).
- **Unknown until a device test:** real libraries (family look-alikes, years apart, low light).
  The founder should run "Find yourself" + a scan on their own phone and watch the review queue.

## 9. Draft email to InsightFace (for the founder to send; not sent)

> **To:** recognition-oss-pack@insightface.ai
> **Cc:** contact@insightface.ai
> **Subject:** Licence quote: buffalo_l (SCRFD-10G + w600k_r50) in one on-device iOS app
>
> Hello,
>
> I run StyleMate, a paid (subscription) iPhone app that builds a digital wardrobe from the user's own
> photo library. To find the user in their photos it needs a face detector with 5-point landmarks and
> a face-embedding model. Everything runs **on the device**: no face data, image or embedding ever
> leaves the phone, and we run no servers.
>
> We would like a quote for a commercial licence to two models from your `buffalo_l` pack:
> `det_10g.onnx` (SCRFD-10G) and `w600k_r50.onnx` (ArcFace R50, WebFace600K).
>
> - **Scope:** one product (StyleMate on iOS / iPadOS), distributed worldwide through the Apple App Store.
> - **Form:** the models converted to Apple Core ML (fp16), bundled inside the app binary. Not
>   redistributed separately and not offered as an SDK or a service.
> - **Volume:** [expected installs in year 1 / year 3, e.g. 20,000 / 150,000]. Price: [planned
>   subscription price].
> - **Term:** we would prefer a perpetual licence for the current model versions, or an annual
>   licence, rather than a per-install royalty.
>
> Could you tell us:
> 1. the price and terms for this scope (flat fee or per-install, and what is included);
> 2. whether the licence covers converting and quantizing the models (Core ML, fp16);
> 3. whether it covers the training data (WebFace600K for the R50), i.e. that we would have no
>    separate obligation to the dataset owners;
> 4. any attribution you require in the app;
> 5. how long contracting usually takes.
>
> Thank you,
> [Name], founder, StyleMate
> [email, company name and address]

## 10. "On you" try-on (Nov 2026) — no new weights

The try-on (docs/TRY-ON.md) ships **no new model**. It uses:

| Component | Licence | Notes |
|---|---|---|
| Apple Vision `VNDetectHumanBodyPoseRequest` | Part of iOS (Apple SDK terms) | Body keypoints. Replaces OpenPose, whose CMU models are non-commercial. |
| The app's garment parser (`WardrobeML.parse`: GarmentNet since 2026-11-06; face / hair / arms / hands / legs derived from its body class by `WardrobeML.splitBody`, face box from Vision) | See §2.10 (commercial) | Read only through its standard classes (`GarmentSegmenter.P`): face / hair / hands / skin / clothing. Swapping the parser (feat/garment-commercial) carries the try-on with it, as long as those classes survive (or are rebuilt from Vision's person mask, §4.3). |
| Marqo-FashionSigLIP | Apache-2.0 (§2.5) | The quality gate. |
| Lykon/dreamshaper-8 (Core ML, `StudioModels.bundle`) | CreativeML OpenRAIL-M (already shipped for studio renders) | The differential-diffusion harmonise pass and the neutral model body. The use restrictions already passed on in the terms cover this use (no impersonation, no non-consensual imagery: the body is the user's own photo or a generated neck-down model). |
| Test fixtures `StyleMateTests/Fixtures/tryon/items/*.png` | Generated by the app's studio pipeline (dreamshaper-8) from the CC0 fixture photos | Test-only. |

Lab-only (never shipped, never in the app or a public artifact): torchvision Keypoint R-CNN (BSD-3 code,
COCO-trained weights) as a stand-in for Vision on Windows, and the FASHN parser as the app's parser.

Off-the-shelf virtual try-on models were checked at their source and **cannot ship** in a paid app:

| Model | Licence (source, read 2026-11-05) | Training data |
|---|---|---|
| OOTDiffusion | `cc-by-nc-sa-4.0` (https://huggingface.co/levihsu/OOTDiffusion) | VITON-HD, Dress Code (both non-commercial research datasets) |
| CatVTON | `cc-by-nc-sa-4.0`; "free to build upon the project for non-commercial purposes" (https://huggingface.co/zhengchong/CatVTON) | VITON-HD, Dress Code, DressCode-MR |
| IDM-VTON | `cc-by-nc-sa-4.0` (https://huggingface.co/yisol/IDM-VTON) | VITON-HD, Dress Code |
| StableVITON | CC BY-NC-SA 4.0 (https://github.com/rlawjdghek/StableVITON) | VITON-HD |

Considered and not used (licence OK, but not worth the size / fidelity trade, docs/TRY-ON.md):
IP-Adapter (`apache-2.0`, https://huggingface.co/h94/IP-Adapter; its image encoder is LAION's OpenCLIP
ViT-H-14, MIT, trained on LAION-2B — the same scraped-data caveat as §3) and ControlNet v1.1 OpenPose
(`openrail`, https://huggingface.co/lllyasviel/control_v11p_sd15_openpose; trained on OpenPose
annotations — the annotator's CMU licence is non-commercial, so its inference-time pose would come
from Apple Vision). Adding either means a new ACK file and another ~0.7–1.2 GB in the app.
