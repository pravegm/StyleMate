# StyleMate model licensing (launch review, 2026-11-04; garment models replaced 2026-11-05)

StyleMate is a paid App Store app that bundles on-device ML models. On 2026-11-04 three of them,
and the training data of a fourth, were licensed for **non-commercial research only**. The two
garment segmenters among them (FASHN parser, Fashionpedia SegFormer) were **replaced on
2026-11-05 by StyleMate's own GarmentNet** (section 2.6); the two face models remain. That is
the biggest single launch blocker. It is a legal risk, not a review risk: App Review will not
spot it, but the licence holders can file a takedown and claim damages after launch.

> **Not legal advice.** The quotes below come from the licence holders' own pages as read on
> 2026-11-04. Before launch, the founder should get counsel to sign off on the final model set,
> especially the "permissive weights trained on research-only data" question in section 3.

## 1. What ships today

| # | Model (bundle name) | Role | Size in app | Weights licence | Paid iOS app may ship it? |
|---|---|---|---|---|---|
| 1 | InsightFace **SCRFD-10G**, `det_10g.onnx` from `buffalo_l` (`SCRFD10G.mlpackage`) | Face detection + 5 landmarks | 8 MB | InsightFace model policy: non-commercial research only | **No**, unless InsightFace grants a commercial licence |
| 2 | **AdaFace IR-101 on WebFace12M** (`MobileFaceNet.mlpackage`) | Face embedding (identity) | 125 MB | Code is MIT. The checkpoint has no stated licence, and its training set (WebFace260M family) is research-only | **No** (no commercial path is known) |
| 3 | **GarmentNet** (`GarmentNet.mlpackage`): StyleMate's own segmenter. Frozen **DINOv2 ViT-S/14-reg4** backbone + a head StyleMate trained from scratch on **Fashionpedia** and **COCO** people (section 2.6) | Garment class per pixel, body vs scene, garment parts | 22 MB | Backbone weights Apache-2.0 (Meta). Head: StyleMate's own, trained on CC BY 4.0 annotations | **Yes**, with attribution (Apache-2.0 notice + CC BY 4.0 credits, in `ACK-14-garmentnet.md`) |
| ~~4~~ | ~~FASHN human parser (`GarmentParser`) and `sayeed99/segformer-b3-fashion` (`GarmentLabeler`)~~ | Removed 2026-11-05 (sections 2.3, 2.4) | — | NVIDIA SegFormer licence (non-commercial) | No longer bundled; CI fails if either is in `StyleMate/ML` or the Release app |
| 5 | **Marqo-FashionSigLIP** (`FashionEncoder.mlpackage` + `FashionVocabulary.json`) | Zero-shot attributes, duplicate matching | 176 MB + 1 MB | Apache-2.0 | **Yes**, with attribution |

Sizes come from CI run 41829764408 (`du -sh`); GarmentNet's from the CI run in section 2.6.

## 2. Each model, in detail

### 2.1 InsightFace SCRFD-10G (from `buffalo_l`)

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

### 2.2 AdaFace IR-101 (WebFace12M)

- **Code:** MIT (https://github.com/mk-minchul/AdaFace).
  - The README gives **no licence for the pretrained checkpoints**. They are Google Drive links in a table.
- **Training data:** WebFace12M is a subset of WebFace260M/WebFace42M (Tsinghua and others). Its licence agreement is https://www.face-benchmark.org/doc/license_agreement_for_webface260m_dataset.pdf.
  - The site's TLS certificate was broken on 2026-11-04, so I could not read the PDF.
  - Every secondary source (papers, dataset indexes) describes WebFace260M as research-only, with no redistribution.
  - InsightFace applies the same "trained on research data = non-commercial" rule to its own WebFace600K models.
- **Verdict: cannot ship.** Nobody offers a commercial licence for these weights. The AdaFace authors (MSU) have no commercial programme, and the dataset licensor is a university consortium. Treat this as having no commercial path.

### 2.3 FASHN human parser (`fashn-ai/fashn-human-parser`) — replaced 2026-11-05

> **No longer shipped.** GarmentNet (section 2.6) replaced it. Its converter is kept, marked
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

> **No longer shipped.** GarmentNet (section 2.6) replaced it (same research-only converter).

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

### 2.6 GarmentNet (StyleMate's garment segmenter, ships from 2026-11-05)

One Core ML model replaces both SegFormers: `StyleMate/ML/GarmentNet.mlpackage`, input 448x672 RGB,
outputs a per-pixel class on the 384x576 analysis grid (0 scene, 1–26 Fashionpedia whole garments,
27 person-not-garment), low-res garment probabilities and hood / collar / lapel / sleeve / person maps.

| Part | What | Licence (verified at the source, 2026-11-05) |
|---|---|---|
| Backbone | **DINOv2 ViT-S/14 with 4 registers**, frozen, layers 8 and 12 (`vit_small_patch14_reg4_dinov2.lvd142m`). Weights: Meta's checkpoint (https://dl.fbaipublicfiles.com/dinov2/dinov2_vits14/dinov2_vits14_reg4_pretrain.pth) as mirrored by timm (https://huggingface.co/timm/vit_small_patch14_reg4_dinov2.lvd142m) | **Apache-2.0** for code *and* weights: "DINOv2 code and model weights are released under the Apache License 2.0" (https://github.com/facebookresearch/dinov2, README "License"). The timm card is tagged apache-2.0. Not the XRay-DINO / Cell-DINO variants, which are NC. |
| Head | ~0.9 M parameters: PCA projection of the two layers (fit on Fashionpedia training images), a token-grid context block, a 4x4 RGB patch stem and a two-step decoder (`scripts/garment/head.py`). **Trained from scratch** (no third-party segmentation checkpoint) | StyleMate's own work |
| Training data: garments | **Fashionpedia** 2020 train set (16,000 images used, plus val 1,158 for model selection): whole-garment masks of the 26 worn classes (umbrella excluded) and the hood / collar / lapel / sleeve part masks, rasterised into person crops and small-item close-ups shaped like the app's (`scripts/garment/fashionpedia.py`). Data from https://github.com/cvdfoundation/fashionpedia (S3 bucket `ifashionist-dataset`) | Annotations **CC BY 4.0** ("The annotations ... are licensed under a Creative Commons Attribution 4.0 License", https://fashionpedia.github.io/home/data_license.html). Images: "Fashionpedia does not own the copyright of the images" — Flickr / Unsplash / Pexels / ... terms of use; used only to compute training features, never redistributed (same caveat as section 3, lower risk). |
| Training data: people | **COCO 2017** train person masks (5,000 images with a large person) teach the person channel (Fashionpedia has no skin / body masks); people's clothes are ignored in the garment loss | Annotations **CC BY 4.0** ("The annotations in this dataset ... are licensed under a Creative Commons Attribution 4.0 License", https://cocodataset.org/#termsofuse). Images under the Flickr terms; training only, never redistributed. |
| Apple Vision | Not used by the garment pipeline. Tried 5 Nov: `VNGeneratePersonSegmentationRequest` as an outer bound never returned inside the CI test host (a 120 s watchdog fired on every attempt), so GarmentNet's own person channel defines body. The upstream multi-person isolation (`FaceMatchingService`, person-instance mask) is unchanged | Apple platform API |
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
  extraction tests never returned, so no Vision request is used by the garment pipeline itself.

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

| Option | Licence (URL) | Landmarks | Notes |
|---|---|---|---|
| **YuNet** (OpenCV Zoo, `face_detection_yunet_2023mar.onnx`) | MIT: "All files in this directory are licensed under MIT License" (https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet). Training repo is BSD-3 (https://github.com/ShiqiYu/libfacedetection.train) | 5 points: right eye, left eye, nose tip, right and left mouth corner. Same set as ArcFace; OpenCV's `FaceRecognizerSF.alignCrop` uses them directly | About 0.3 MB, tiny and fast. Trained on WIDER FACE (see §3). Converts to Core ML through ONNX → PyTorch (`onnx2torch`, already used for SCRFD). **Best drop-in.** |
| InsightFace `buffalo_l` (SCRFD-10G) **with a commercial licence** | Contract with InsightFace (§2.1) | Same as today | Zero engineering if the licence comes through. Price and lead time unknown. |
| MediaPipe Face Detector (BlazeFace) + Face Landmarker | Apache-2.0 (https://github.com/google-ai-edge/mediapipe; model cards linked from https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker) | BlazeFace gives 6 keypoints (eyes, nose tip, mouth centre, ear tragions) but **no mouth corners**. Face Landmarker gives 478 points, so mouth corners are available | Two models per face. BlazeFace short-range is tuned for selfie distance and weak on small faces in group or street photos. iOS SDK via CocoaPods `MediaPipeTasksVision`. |
| dlib MMOD detector + `shape_predictor_5_face_landmarks` | Public domain / CC0: "anyone can do whatever they want with these model files" (https://github.com/davisking/dlib-models) | dlib's own 5 points (four eye corners + nose base), **not** ArcFace's 5 | Cleanest licence statement of all, but needs dlib C++ on iOS or a port. Older and slower. Avoid the 68-point model, which is non-commercial (iBUG 300-W). |
| Apple Vision `VNDetectFaceRectanglesRequest` | Part of iOS | Not usable as-is | CLAUDE.md records that Vision landmarks collapsed same-person similarity (0.988 → about 0.2). Usable only as a box proposer in front of YuNet landmarks. |

### 4.2 Face recognition (replaces AdaFace)

| Option | Licence (URL) | Quality | Notes |
|---|---|---|---|
| **InsightFace `w600k_r50` from `buffalo_l` with a commercial licence** | Contract (§2.1) | Close to AdaFace on clean photos (ArcFace R50 on WebFace600K) | `scripts/convert_r50.py` already exists. Input is RGB, so undo the BGR plane swap in `createInputMultiArray` and bump `FaceMatchingService.modelVersion`. **Best quality per dollar if the price is acceptable.** |
| InsightFace InspireFace SDK / closed models | Contract (contact@insightface.ai) | Vendor claims higher than open packs | A full SDK, so it would replace more of the pipeline. Enterprise-oriented. |
| **SFace** (OpenCV Zoo, `face_recognition_sface_2021dec.onnx`) | Apache-2.0: "All files in this directory are licensed under Apache 2.0 License" (https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) | LFW 99.40% (OpenCV's table). MobileFaceNet-sized, so expect a **clearly lower** hit rate than IR-101 on profile, low-light, sunglasses and small faces | 128-d output, 112×112 aligned, same ArcFace alignment template as now. OpenCV does not state the training data (§3). **Best free option.** |
| dlib `dlib_face_recognition_resnet_model_v1` | Public domain / CC0 (https://github.com/davisking/dlib-models) | LFW 99.38%. Trained on about 3M faces (FaceScrub, VGG, scraped) | Has its own alignment (dlib 5-point), so it must be paired with dlib's landmarker. Port effort is higher than SFace. |
| Commercial on-device SDKs (Luxand FaceSDK, Regula, Neurotechnology VeriLook, Paravision and others) | Contract. Luxand is quote-only (sales@luxand.com; https://www.luxand.com/facesdk/) | Varies | Adds a closed binary and a per-app or per-install fee. Check that they process fully on-device (no server or telemetry), or the privacy story breaks. |

### 4.3 Garment segmentation (replaces FASHN + the Fashionpedia SegFormer)

> **Done 2026-11-05: option 2 shipped as GarmentNet (section 2.6)** — DINOv2 ViT-S/14 frozen + a head trained on Fashionpedia,
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

The garment retrain (§4.3 option 2) was on the critical path whatever happens with face models. **It is done (GarmentNet, section 2.6, 2026-11-05)**; only the face models remain.

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
    references). **Whoever adds or swaps a model adds / deletes its file there.** Still to add if they keep
    shipping: SCRFD / AdaFace / FASHN parser / Fashionpedia labeler texts (NVIDIA SegFormer licence §3.1 asks
    for a copy of the licence with any redistribution; Fashionpedia annotations are CC BY 4.0).
  - Open-Meteo's licence also asks for a link "next to any location Open-Meteo data are displayed"; the weather
    card shows none yet.
- Record each shipped model's source URL, licence, commit or hash and conversion script in this file. Bump `FaceMatchingService.modelVersion` on any face-model swap (CLAUDE.md).
- Keep the weights out of public artifacts. The repo is **public**; CI keeps the models only in the Actions cache, which is correct.
