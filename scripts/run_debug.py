#!/usr/bin/env python3
"""
Runs the EXACT app pipeline on real user photos placed in debug_photos/:
  SCRFD detect (+ padding fallback) -> warpAligned -> AdaFace embed (BGR)
then prints a same-person cosine matrix. EXIF orientation is applied (as the app
does), and we also report what happens WITHOUT it, to catch orientation bugs.

Usage: drop selfie + a couple library photos in scripts/debug_photos/, then run.
"""
import cv2, numpy as np, torch, coremltools as ct, glob, os
from pathlib import Path
from PIL import Image, ImageOps
import pillow_heif
pillow_heif.register_heif_opener()
import adaface_net as net
from insightface.utils import face_align  # only for ARCFACE_DST sanity, not used in pipeline

SCRIPT = Path(__file__).parent
m = net.build_model("ir_101")
sd = torch.load(str(SCRIPT/"adaface_ir101_webface12m.ckpt"), map_location="cpu")["state_dict"]
m.load_state_dict({k[6:]:v for k,v in sd.items() if k.startswith("model.")}); m.eval()
def embed(a):
    t=(a.astype(np.float32)-127.5)/127.5
    t=torch.from_numpy(np.ascontiguousarray(t.transpose(2,0,1))[None])
    with torch.no_grad(): f=m(t)[0][0].numpy()
    return f/(np.linalg.norm(f)+1e-9)
def cos(a,b): return float(np.dot(a,b))

ml=ct.models.MLModel(str(SCRIPT/"SCRFD10G.mlpackage")); inname=ml.get_spec().description.input[0].name
STRIDES=[8,16,32]
def anchors(s):
    hw=640//s; ac=np.stack(np.mgrid[:hw,:hw][::-1],axis=-1).astype(np.float32)
    ac=(ac*s).reshape(-1,2); return np.stack([ac,ac],axis=1).reshape(-1,2)
AC={s:anchors(s) for s in STRIDES}
def _detect(bgr,thr=0.5):
    rgb=cv2.cvtColor(bgr,cv2.COLOR_BGR2RGB); h,w=rgb.shape[:2]; S=640; scale=min(S/w,S/h)
    nw,nh=min(S,round(w*scale)),min(S,round(h*scale))
    canvas=np.zeros((S,S,3),np.float32); canvas[:nh,:nw]=cv2.resize(rgb,(nw,nh))
    blob=((canvas-127.5)/128).transpose(2,0,1)[None].astype(np.float32)
    out=ml.predict({inname:blob})
    def pick(L,inner):
        for k,v in out.items():
            a=np.array(v)
            if a.shape[0]==L and a.shape[1]==inner: return a
    res=[]
    for s in STRIDES:
        L=(640//s)**2*2; sc=pick(L,1)[:,0]; bb=pick(L,4)*s; kp=pick(L,10)*s; ac=AC[s]
        for i in np.where(sc>=thr)[0]:
            x1,y1=ac[i,0]-bb[i,0],ac[i,1]-bb[i,1]; x2,y2=ac[i,0]+bb[i,2],ac[i,1]+bb[i,3]
            pts=np.array([[ac[i,0]+kp[i,j*2],ac[i,1]+kp[i,j*2+1]] for j in range(5)],np.float32)/scale
            res.append((sc[i],np.array([x1,y1,x2,y2])/scale,pts))
    return sorted(res,key=lambda r:-r[0])
def detect(bgr):
    d=_detect(bgr)
    if d: return d
    mw,mh=bgr.shape[1]*2//5,bgr.shape[0]*2//5
    padded=cv2.copyMakeBorder(bgr,mh,mh,mw,mw,cv2.BORDER_CONSTANT,value=0)
    d=_detect(padded)
    return [(s,b-np.array([mw,mh,mw,mh]),k-np.array([mw,mh])) for s,b,k in d]

ARCFACE_DST=np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],
                      [41.5493,92.3655],[70.7299,92.2041]],np.float32)
def warp(bgr,kps):
    ata=np.zeros((4,4)); atb=np.zeros(4)
    for i in range(5):
        sx,sy=kps[i]; dx,dy=ARCFACE_DST[i]
        for row,d in (([sx,-sy,1,0],dx),([sy,sx,0,1],dy)):
            row=np.array(row,float); ata+=np.outer(row,row); atb+=row*d
    a,b,tx,ty=np.linalg.solve(ata,atb); det=a*a+b*b
    out=np.zeros((112,112,3),np.uint8); H,W=bgr.shape[:2]
    for oy in range(112):
        for ox in range(112):
            sx=(a*(ox-tx)+b*(oy-ty))/det; sy=(-b*(ox-tx)+a*(oy-ty))/det
            if sx<0 or sy<0 or sx>=W-1 or sy>=H-1: continue
            x0,y0=int(sx),int(sy); fx,fy=sx-x0,sy-y0
            for c in range(3):
                out[oy,ox,c]=min(max(int(bgr[y0,x0,c]*(1-fx)*(1-fy)+bgr[y0,x0+1,c]*fx*(1-fy)+
                    bgr[y0+1,x0,c]*(1-fx)*fy+bgr[y0+1,x0+1,c]*fx*fy),0),255)
    return out

def load_bgr(path, apply_exif=True):
    im=Image.open(path).convert("RGB")
    if apply_exif: im=ImageOps.exif_transpose(im)
    return cv2.cvtColor(np.array(im), cv2.COLOR_RGB2BGR)

files=sorted([f for f in glob.glob(str(SCRIPT/"debug_photos"/"*")) if f.lower().endswith((".jpg",".jpeg",".png",".heic",".heif"))])
if not files:
    print("No images in scripts/debug_photos/. Drop your selfie + 2 photos there and re-run."); raise SystemExit
labels=[]; embs=[]
for f in files:
    name=os.path.basename(f).replace(".jpeg","").replace(".jpg","").replace(".heic","")
    bgr=load_bgr(f, apply_exif=True)
    d=detect(bgr)
    if not d:
        print(f"{name}: NO FACE DETECTED ({bgr.shape[1]}x{bgr.shape[0]})"); continue
    d=sorted(d,key=lambda r:-(r[1][2]-r[1][0])*(r[1][3]-r[1][1]))[:3]  # up to 3 biggest faces
    print(f"{name}: {len(d)} face(s) used, img {bgr.shape[1]}x{bgr.shape[0]}")
    for k,(score,box,kps) in enumerate(d):
        labels.append(f"{name[:6]}#{k}"); embs.append(embed(warp(bgr,kps)))

print("\nFull per-face cosine matrix (your face across photos should be 0.5-0.9):")
print("            "+"  ".join(f"{l:>10}" for l in labels))
for i,a in enumerate(labels):
    print(f"{a:>10}  "+"  ".join(f"{cos(embs[i],embs[j]):>10.3f}" for j in range(len(labels))))
